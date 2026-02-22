//! String scanning and comparison primitives for the JSON scanner.
//!
//! Operates directly on []const u8 buffers with zero allocation.
//! All functions perform explicit bounds checking before every byte access.
//! Handles all eight JSON escape sequences: \\, \", \/, \b, \f, \n, \r, \t
//! and \uXXXX unicode escapes (structural validation only -- 4 hex digits
//! must follow \u, but surrogate pair semantics are not validated).
const std = @import("std");
const types = @import("types.zig");

const Pos = types.Pos;
const ScanError = types.ScanError;

/// Advances past a complete JSON string starting at `pos`.
///
/// `pos` must point to the opening double-quote. Returns the position
/// immediately after the closing double-quote. Validates all escape
/// sequences and rejects unescaped control characters (bytes < 0x20).
pub fn skipString(buffer: []const u8, pos: Pos) ScanError!Pos {
    std.debug.assert(pos < buffer.len);
    std.debug.assert(buffer[pos] == '"');

    var cursor: Pos = pos + 1;

    while (true) {
        if (cursor >= buffer.len) {
            return ScanError.UnexpectedEndOfInput;
        }

        const byte = buffer[cursor];

        if (byte == '"') {
            // Closing quote found -- return position after it.
            return cursor + 1;
        }

        if (byte == '\\') {
            // Escape sequence: consume the backslash and validate the next byte.
            cursor += 1;
            if (cursor >= buffer.len) {
                return ScanError.UnexpectedEndOfInput;
            }
            const escaped = buffer[cursor];
            switch (escaped) {
                '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                    cursor += 1;
                },
                'u' => {
                    // \uXXXX -- must have exactly 4 hex digits.
                    cursor += 1;
                    cursor = try consumeHexDigits(buffer, cursor, 4);
                },
                else => {
                    return ScanError.InvalidEscape;
                },
            }
            continue;
        }

        if (byte < 0x20) {
            // Unescaped control character inside a string.
            return ScanError.UnexpectedByte;
        }

        cursor += 1;
    }
}

/// Compares a JSON-encoded key in the buffer against an unescaped search term.
///
/// The key span must include the surrounding double-quotes. The search term
/// is raw bytes (not JSON-encoded). The comparison decodes escape sequences
/// in the buffer key on the fly and compares decoded bytes against the search
/// term. Returns true if the decoded key content exactly equals `search_term`.
pub fn stringEquals(buffer: []const u8, key_span: types.Span, search_term: []const u8) bool {
    std.debug.assert(key_span.end >= key_span.start);
    std.debug.assert(key_span.end <= buffer.len);

    const raw = key_span.slice(buffer);

    // Key must have at least opening and closing quotes.
    if (raw.len < 2) return false;
    if (raw[0] != '"' or raw[raw.len - 1] != '"') return false;

    // Walk the key content (between quotes) decoding escapes.
    var key_cursor: usize = 1;
    var search_cursor: usize = 0;
    const key_end: usize = raw.len - 1;

    while (key_cursor < key_end and search_cursor < search_term.len) {
        if (raw[key_cursor] == '\\') {
            key_cursor += 1;
            if (key_cursor >= key_end) return false;
            const decoded = decodeEscape(raw[key_cursor]);
            if (decoded) |byte| {
                if (byte != search_term[search_cursor]) return false;
                key_cursor += 1;
                search_cursor += 1;
            } else {
                // \uXXXX -- decode to UTF-8 bytes and compare.
                if (raw[key_cursor] != 'u') return false;
                key_cursor += 1;
                if (key_cursor + 4 > key_end) return false;
                const codepoint = parseHexU16(raw[key_cursor..][0..4]) orelse return false;
                var utf8_buffer: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(@intCast(codepoint), &utf8_buffer) catch return false;
                if (search_cursor + utf8_len > search_term.len) return false;
                if (!std.mem.eql(u8, utf8_buffer[0..utf8_len], search_term[search_cursor..][0..utf8_len])) return false;
                key_cursor += 4;
                search_cursor += utf8_len;
            }
        } else {
            if (raw[key_cursor] != search_term[search_cursor]) return false;
            key_cursor += 1;
            search_cursor += 1;
        }
    }

    // Both must be fully consumed for equality.
    return key_cursor == key_end and search_cursor == search_term.len;
}

/// Returns the decoded content of a JSON string (between the quotes) as a
/// newly allocated slice. Caller owns the returned memory.
///
/// The span must include the surrounding double-quotes.
pub fn stringContent(allocator: std.mem.Allocator, buffer: []const u8, span: types.Span) ![]u8 {
    std.debug.assert(span.end >= span.start);
    std.debug.assert(span.end <= buffer.len);

    const raw = span.slice(buffer);
    if (raw.len < 2) return error.UnexpectedEndOfInput;

    var result = std.ArrayList(u8){};
    errdefer result.deinit(allocator);

    var cursor: usize = 1;
    const end: usize = raw.len - 1;

    while (cursor < end) {
        if (raw[cursor] == '\\') {
            cursor += 1;
            if (cursor >= end) return error.UnexpectedEndOfInput;
            const decoded = decodeEscape(raw[cursor]);
            if (decoded) |byte| {
                try result.append(allocator, byte);
                cursor += 1;
            } else if (raw[cursor] == 'u') {
                cursor += 1;
                if (cursor + 4 > end) return error.UnexpectedEndOfInput;
                const codepoint = parseHexU16(raw[cursor..][0..4]) orelse return error.InvalidUnicodeEscape;
                var utf8_buffer: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(@intCast(codepoint), &utf8_buffer) catch return error.InvalidUnicodeEscape;
                try result.appendSlice(allocator, utf8_buffer[0..utf8_len]);
                cursor += 4;
            } else {
                return error.InvalidEscape;
            }
        } else {
            try result.append(allocator, raw[cursor]);
            cursor += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Returns the decoded byte length of a JSON string's content (between quotes)
/// without allocating. Useful for size estimation.
///
/// The span must include the surrounding double-quotes.
pub fn stringContentLength(buffer: []const u8, span: types.Span) ScanError!u32 {
    std.debug.assert(span.end >= span.start);
    std.debug.assert(span.end <= buffer.len);

    const raw = span.slice(buffer);
    if (raw.len < 2) return ScanError.UnexpectedEndOfInput;

    var cursor: usize = 1;
    const end: usize = raw.len - 1;
    var length: u32 = 0;

    while (cursor < end) {
        if (raw[cursor] == '\\') {
            cursor += 1;
            if (cursor >= end) return ScanError.UnexpectedEndOfInput;
            const escaped = raw[cursor];
            if (escaped == 'u') {
                cursor += 1;
                if (cursor + 4 > end) return ScanError.UnexpectedEndOfInput;
                const codepoint = parseHexU16(raw[cursor..][0..4]) orelse return ScanError.InvalidUnicodeEscape;
                length += std.unicode.utf8CodepointSequenceLength(@intCast(codepoint)) catch return ScanError.InvalidUnicodeEscape;
                cursor += 4;
            } else {
                // Single-byte escape: \", \\, \/, \b, \f, \n, \r, \t
                length += 1;
                cursor += 1;
            }
        } else {
            length += 1;
            cursor += 1;
        }
    }

    std.debug.assert(cursor == end);
    return length;
}

// -- Internal helpers --

/// Decode a single-character JSON escape (the byte after the backslash).
/// Returns null for 'u' (which requires special handling) and for invalid escapes.
fn decodeEscape(byte: u8) ?u8 {
    return switch (byte) {
        '"' => '"',
        '\\' => '\\',
        '/' => '/',
        'b' => 0x08,
        'f' => 0x0C,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        else => null,
    };
}

/// Consume exactly `count` hex digits starting at `cursor`.
/// Returns the position after the last hex digit, or an error.
fn consumeHexDigits(buffer: []const u8, start: Pos, count: u8) ScanError!Pos {
    var cursor = start;
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (cursor >= buffer.len) {
            return ScanError.UnexpectedEndOfInput;
        }
        const byte = buffer[cursor];
        const is_hex = (byte >= '0' and byte <= '9') or
            (byte >= 'a' and byte <= 'f') or
            (byte >= 'A' and byte <= 'F');
        if (!is_hex) {
            return ScanError.InvalidUnicodeEscape;
        }
        cursor += 1;
    }
    return cursor;
}

/// Parse 4 hex ASCII digits into a u16 value. Returns null on invalid input.
fn parseHexU16(digits: *const [4]u8) ?u16 {
    var result: u16 = 0;
    for (digits) |digit| {
        const nibble: u16 = switch (digit) {
            '0'...'9' => digit - '0',
            'a'...'f' => digit - 'a' + 10,
            'A'...'F' => digit - 'A' + 10,
            else => return null,
        };
        result = result * 16 + nibble;
    }
    return result;
}
