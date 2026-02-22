//! Core byte-level JSON structural scanner.
//!
//! Operates directly on []const u8 with zero heap allocation. All state lives
//! on the stack or in the caller-provided buffer. The scanner finds value
//! boundaries (positions and spans) without building a parse tree.
//!
//! Entry point: scanValue validates a complete JSON document.
//! Core primitive: skipValue dispatches by first byte to advance past one value.
const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const scanner_strings = @import("scanner_strings.zig");

const Pos = types.Pos;
const Span = types.Span;
const ValueType = types.ValueType;
const ScanError = types.ScanError;
const BracketKind = types.BracketKind;

/// Validates a complete JSON document in `buffer`.
///
/// Skips leading whitespace, scans the root value via skipValue, then verifies
/// that only whitespace follows. A buffer like `[1,2,3] garbage` is rejected
/// with ScanError.TrailingContent.
pub fn scanValue(buffer: []const u8) ScanError!Span {
    std.debug.assert(buffer.len > 0);

    const start = skipWhitespace(buffer, 0);
    if (start >= buffer.len) {
        return ScanError.UnexpectedEndOfInput;
    }

    const end = try skipValue(buffer, start);

    // Verify no trailing non-whitespace content.
    const trailing_start = skipWhitespace(buffer, end);
    if (trailing_start < buffer.len) {
        return ScanError.TrailingContent;
    }

    std.debug.assert(end > start);
    return Span{ .start = start, .end = end };
}

/// Classifies the JSON value type from the first byte at `pos`.
///
/// Does not advance the position. Returns the ValueType or an error
/// if the byte cannot begin a JSON value.
pub fn classifyValue(buffer: []const u8, pos: Pos) ScanError!ValueType {
    std.debug.assert(pos < buffer.len);

    return switch (buffer[pos]) {
        '"' => .string,
        '{' => .object,
        '[' => .array,
        't', 'f' => .boolean,
        'n' => .null_type,
        '-', '0'...'9' => .number,
        else => ScanError.UnexpectedByte,
    };
}

/// Advances past one complete JSON value starting at `pos`.
///
/// Dispatches by first byte: strings, containers (iterative with bracket
/// stack), numbers, and literals. Returns the position immediately after
/// the value. All container nesting is tracked with a fixed-size stack
/// (max_nesting_depth = 256), not recursion.
pub fn skipValue(buffer: []const u8, pos: Pos) ScanError!Pos {
    std.debug.assert(pos < buffer.len);

    const byte = buffer[pos];

    return switch (byte) {
        '"' => scanner_strings.skipString(buffer, pos),
        '{', '[' => skipContainer(buffer, pos),
        '-', '0'...'9' => skipNumber(buffer, pos),
        't' => skipLiteral(buffer, pos, "true"),
        'f' => skipLiteral(buffer, pos, "false"),
        'n' => skipLiteral(buffer, pos, "null"),
        else => ScanError.UnexpectedByte,
    };
}

/// Advances past whitespace (space, tab, newline, carriage return).
/// Returns the position of the next non-whitespace byte, or buffer.len
/// if the remainder is all whitespace.
pub fn skipWhitespace(buffer: []const u8, pos: Pos) Pos {
    var cursor = pos;
    while (cursor < buffer.len) {
        switch (buffer[cursor]) {
            ' ', '\t', '\n', '\r' => cursor += 1,
            else => break,
        }
    }
    return cursor;
}

/// Advances past a JSON number starting at `pos`.
///
/// Validates per RFC 8259: optional leading minus, integer part (no leading
/// zeros except bare 0), optional fractional part, optional exponent.
/// Rejects: 007, 1., .5, 1e (missing exponent digits).
pub fn skipNumber(buffer: []const u8, pos: Pos) ScanError!Pos {
    std.debug.assert(pos < buffer.len);

    var cursor: Pos = pos;

    // Optional leading minus.
    if (buffer[cursor] == '-') {
        cursor += 1;
        if (cursor >= buffer.len) {
            return ScanError.UnexpectedEndOfInput;
        }
    }

    // Integer part.
    if (cursor >= buffer.len) {
        return ScanError.UnexpectedEndOfInput;
    }
    if (buffer[cursor] == '0') {
        cursor += 1;
        // After a leading 0, the next character must not be a digit (no 007).
        if (cursor < buffer.len and buffer[cursor] >= '0' and buffer[cursor] <= '9') {
            return ScanError.InvalidNumber;
        }
    } else if (buffer[cursor] >= '1' and buffer[cursor] <= '9') {
        cursor += 1;
        while (cursor < buffer.len and buffer[cursor] >= '0' and buffer[cursor] <= '9') {
            cursor += 1;
        }
    } else {
        return ScanError.InvalidNumber;
    }

    // Optional fractional part.
    if (cursor < buffer.len and buffer[cursor] == '.') {
        cursor += 1;
        if (cursor >= buffer.len or buffer[cursor] < '0' or buffer[cursor] > '9') {
            return ScanError.InvalidNumber;
        }
        while (cursor < buffer.len and buffer[cursor] >= '0' and buffer[cursor] <= '9') {
            cursor += 1;
        }
    }

    // Optional exponent.
    if (cursor < buffer.len and (buffer[cursor] == 'e' or buffer[cursor] == 'E')) {
        cursor += 1;
        if (cursor >= buffer.len) {
            return ScanError.UnexpectedEndOfInput;
        }
        // Optional sign.
        if (buffer[cursor] == '+' or buffer[cursor] == '-') {
            cursor += 1;
            if (cursor >= buffer.len) {
                return ScanError.UnexpectedEndOfInput;
            }
        }
        // At least one exponent digit required.
        if (buffer[cursor] < '0' or buffer[cursor] > '9') {
            return ScanError.InvalidNumber;
        }
        while (cursor < buffer.len and buffer[cursor] >= '0' and buffer[cursor] <= '9') {
            cursor += 1;
        }
    }

    std.debug.assert(cursor > pos);
    return cursor;
}

/// Advances past a JSON literal (true, false, null) starting at `pos`.
///
/// The expected literal must match byte-for-byte. Truncated or misspelled
/// literals return appropriate errors.
pub fn skipLiteral(buffer: []const u8, pos: Pos, expected: []const u8) ScanError!Pos {
    std.debug.assert(pos < buffer.len);
    std.debug.assert(expected.len > 0);

    if (pos + expected.len > buffer.len) {
        return ScanError.UnexpectedEndOfInput;
    }

    const actual = buffer[pos..][0..expected.len];
    if (!std.mem.eql(u8, actual, expected)) {
        return ScanError.InvalidLiteral;
    }

    return @as(Pos, @intCast(pos + expected.len));
}

/// Computes the number of bytes a value would occupy in compact (minimized)
/// JSON. Insignificant whitespace is excluded; literal spaces inside strings
/// are preserved. This is a full scan (comparable to skipValue in cost).
///
/// The span must point to a valid JSON value in `buffer`.
pub fn compactSize(buffer: []const u8, span: Span) ScanError!u32 {
    std.debug.assert(span.end >= span.start);
    std.debug.assert(span.end <= buffer.len);

    const data = span.slice(buffer);
    if (data.len == 0) {
        return 0;
    }

    var size: u32 = 0;
    var cursor: u32 = 0;
    var inside_string: bool = false;

    while (cursor < data.len) {
        const byte = data[cursor];

        if (inside_string) {
            size += 1;
            if (byte == '"') {
                inside_string = false;
            } else if (byte == '\\') {
                // Escape sequence: count the escaped byte too.
                cursor += 1;
                if (cursor < data.len) {
                    size += 1;
                    if (data[cursor] == 'u') {
                        // \uXXXX: count the 4 hex digits.
                        const hex_end = @min(cursor + 5, @as(u32, @intCast(data.len)));
                        const hex_count = hex_end - cursor - 1;
                        size += hex_count;
                        cursor += 1 + hex_count;
                        continue;
                    }
                }
            }
            cursor += 1;
            continue;
        }

        // Outside a string: skip insignificant whitespace.
        switch (byte) {
            ' ', '\t', '\n', '\r' => {
                cursor += 1;
            },
            '"' => {
                inside_string = true;
                size += 1;
                cursor += 1;
            },
            else => {
                size += 1;
                cursor += 1;
            },
        }
    }

    std.debug.assert(size > 0 or span.len() == 0);
    return size;
}

// -- Navigation and iteration --

/// Caller-driven iterator over top-level elements of an array or object.
///
/// Yields (start, end) spans for each element without buffering. For arrays,
/// each element is a value. For objects, each element starts at the key and
/// ends after the value. The iterator skips whitespace and structural commas
/// between elements.
pub const TopLevelIterator = struct {
    buffer: []const u8,
    cursor: Pos,
    container_end: Pos,
    container_kind: BracketKind,

    /// Initialize an iterator for a container starting at `container_start`.
    /// The container_start must point to '[' or '{'.
    pub fn init(buffer: []const u8, container_start: Pos) ScanError!TopLevelIterator {
        std.debug.assert(container_start < buffer.len);
        std.debug.assert(buffer[container_start] == '[' or buffer[container_start] == '{');

        const container_end = try skipValue(buffer, container_start);
        const kind: BracketKind = if (buffer[container_start] == '[') .array else .object;

        std.debug.assert(container_end > container_start);
        return TopLevelIterator{
            .buffer = buffer,
            .cursor = container_start + 1,
            .container_end = container_end,
            .container_kind = kind,
        };
    }

    /// Returns the next element span, or null when exhausted.
    /// For objects, the span covers key+colon+value.
    pub fn next(self: *TopLevelIterator) ScanError!?Span {
        // Skip whitespace and commas.
        var cursor = skipWhitespace(self.buffer, self.cursor);
        if (cursor >= self.container_end - 1) {
            return null;
        }
        if (self.buffer[cursor] == ',') {
            cursor += 1;
            cursor = skipWhitespace(self.buffer, cursor);
        }
        if (cursor >= self.container_end - 1) {
            return null;
        }

        const element_start = cursor;

        if (self.container_kind == .object) {
            // Object element: skip key, colon, value.
            cursor = try scanner_strings.skipString(self.buffer, cursor);
            cursor = skipWhitespace(self.buffer, cursor);
            if (cursor >= self.buffer.len or self.buffer[cursor] != ':') {
                return ScanError.UnexpectedByte;
            }
            cursor += 1;
            cursor = skipWhitespace(self.buffer, cursor);
            cursor = try skipValue(self.buffer, cursor);
        } else {
            // Array element: skip one value.
            cursor = try skipValue(self.buffer, cursor);
        }

        self.cursor = cursor;
        std.debug.assert(cursor > element_start);
        return Span{ .start = element_start, .end = cursor };
    }
};

/// Navigates a parsed path through the buffer, returning the span of the
/// target value. Each segment descends into an object (by key) or array
/// (by index). Skips irrelevant values entirely.
pub fn navigatePath(
    buffer: []const u8,
    start: Pos,
    segments: []const types.PathSegment,
) (ScanError || types.PathError)!Span {
    std.debug.assert(start < buffer.len);

    var current_pos = start;

    for (segments) |segment| {
        const ws_pos = skipWhitespace(buffer, current_pos);
        if (ws_pos >= buffer.len) {
            return ScanError.UnexpectedEndOfInput;
        }
        current_pos = ws_pos;

        switch (segment) {
            .key => |key_name| {
                current_pos = try objectValueForKey(buffer, current_pos, key_name);
            },
            .index => |index_value| {
                current_pos = try arrayElementAt(buffer, current_pos, index_value);
            },
        }
    }

    // Now current_pos points to the target value. Determine its span.
    const ws_pos = skipWhitespace(buffer, current_pos);
    if (ws_pos >= buffer.len) {
        return ScanError.UnexpectedEndOfInput;
    }
    const value_end = try skipValue(buffer, ws_pos);

    std.debug.assert(value_end > ws_pos);
    return Span{ .start = ws_pos, .end = value_end };
}

/// Finds the value associated with a key in a JSON object.
///
/// `pos` must point to the opening '{'. Returns the position of the first
/// non-whitespace byte of the value for the matching key. Scans keys using
/// stringEquals (zero-copy comparison). Returns PathError.KeyNotFound if
/// the key does not exist. Returns PathError.NotAnObject if pos does not
/// point to '{'.
pub fn objectValueForKey(
    buffer: []const u8,
    pos: Pos,
    key_name: []const u8,
) (ScanError || types.PathError)!Pos {
    std.debug.assert(pos < buffer.len);

    if (buffer[pos] != '{') {
        return types.PathError.NotAnObject;
    }

    var cursor: Pos = pos + 1;

    while (true) {
        cursor = skipWhitespace(buffer, cursor);
        if (cursor >= buffer.len) {
            return ScanError.UnexpectedEndOfInput;
        }
        if (buffer[cursor] == '}') {
            return types.PathError.KeyNotFound;
        }
        if (buffer[cursor] == ',') {
            cursor += 1;
            cursor = skipWhitespace(buffer, cursor);
            if (cursor >= buffer.len) {
                return ScanError.UnexpectedEndOfInput;
            }
        }

        // Read key string.
        if (buffer[cursor] != '"') {
            return ScanError.UnexpectedByte;
        }
        const key_start = cursor;
        const key_end = try scanner_strings.skipString(buffer, cursor);
        const key_span = Span{ .start = key_start, .end = key_end };

        // Skip colon.
        cursor = skipWhitespace(buffer, key_end);
        if (cursor >= buffer.len or buffer[cursor] != ':') {
            return ScanError.UnexpectedByte;
        }
        cursor += 1;
        cursor = skipWhitespace(buffer, cursor);

        if (scanner_strings.stringEquals(buffer, key_span, key_name)) {
            return cursor;
        }

        // Skip the value.
        if (cursor >= buffer.len) {
            return ScanError.UnexpectedEndOfInput;
        }
        cursor = try skipValue(buffer, cursor);
    }
}

/// Finds the N-th element (0-based) in a JSON array.
///
/// `pos` must point to the opening '['. Returns the position of the first
/// non-whitespace byte of the target element. Returns PathError.IndexOutOfRange
/// if the array has fewer elements. Returns PathError.NotAnArray if pos does
/// not point to '['.
pub fn arrayElementAt(
    buffer: []const u8,
    pos: Pos,
    index: u32,
) (ScanError || types.PathError)!Pos {
    std.debug.assert(pos < buffer.len);

    if (buffer[pos] != '[') {
        return types.PathError.NotAnArray;
    }

    var cursor: Pos = pos + 1;
    var current_index: u32 = 0;

    while (true) {
        cursor = skipWhitespace(buffer, cursor);
        if (cursor >= buffer.len) {
            return ScanError.UnexpectedEndOfInput;
        }
        if (buffer[cursor] == ']') {
            return types.PathError.IndexOutOfRange;
        }
        if (buffer[cursor] == ',') {
            cursor += 1;
            cursor = skipWhitespace(buffer, cursor);
            if (cursor >= buffer.len) {
                return ScanError.UnexpectedEndOfInput;
            }
        }

        if (current_index == index) {
            return cursor;
        }

        // Skip this element.
        cursor = try skipValue(buffer, cursor);
        current_index += 1;
    }
}

// -- Internal helpers --

/// Iterative container scanner using a fixed-size bracket stack.
///
/// Handles both arrays and objects. Validates bracket matching ({/} and [/])
/// and enforces max_nesting_depth. Does not validate internal grammar beyond
/// structural balance -- comma and colon placement are not checked because
/// the scanner only needs to find value boundaries.
fn skipContainer(buffer: []const u8, pos: Pos) ScanError!Pos {
    std.debug.assert(pos < buffer.len);
    std.debug.assert(buffer[pos] == '{' or buffer[pos] == '[');

    var bracket_stack: [config.max_nesting_depth]BracketKind = undefined;
    var depth: u16 = 0;
    var cursor: Pos = pos;

    // Push the opening bracket.
    const opening_kind: BracketKind = if (buffer[cursor] == '[') .array else .object;
    bracket_stack[0] = opening_kind;
    depth = 1;
    cursor += 1;

    while (cursor < buffer.len) {
        const byte = buffer[cursor];

        switch (byte) {
            // Whitespace and structural tokens we skip over.
            ' ', '\t', '\n', '\r', ',', ':' => {
                cursor += 1;
            },
            '"' => {
                cursor = try scanner_strings.skipString(buffer, cursor);
            },
            '{', '[' => {
                if (depth >= config.max_nesting_depth) {
                    return ScanError.NestingDepthExceeded;
                }
                bracket_stack[depth] = if (byte == '[') .array else .object;
                depth += 1;
                cursor += 1;
            },
            '}', ']' => {
                if (depth == 0) {
                    return ScanError.UnexpectedByte;
                }
                const expected_kind: BracketKind = bracket_stack[depth - 1];
                const actual_kind: BracketKind = if (byte == ']') .array else .object;
                if (expected_kind != actual_kind) {
                    return ScanError.MismatchedBracket;
                }
                depth -= 1;
                cursor += 1;
                if (depth == 0) {
                    return cursor;
                }
            },
            '-', '0'...'9' => {
                cursor = try skipNumber(buffer, cursor);
            },
            't' => {
                cursor = try skipLiteral(buffer, cursor, "true");
            },
            'f' => {
                cursor = try skipLiteral(buffer, cursor, "false");
            },
            'n' => {
                cursor = try skipLiteral(buffer, cursor, "null");
            },
            else => {
                return ScanError.UnexpectedByte;
            },
        }
    }

    // If we reach here, the container was never closed.
    return ScanError.UnexpectedEndOfInput;
}
