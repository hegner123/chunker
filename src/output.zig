//! Zero-copy JSON output assembly.
//!
//! Builds compact JSON output from scanner spans by slicing the original
//! buffer. This is the only phase that allocates (tier 2: arena).
//! Calls scanner.compactSize -- does not reimplement it.
const std = @import("std");
const types = @import("types.zig");
const scanner = @import("scanner.zig");
const scanner_strings = @import("scanner_strings.zig");

const Pos = types.Pos;
const Span = types.Span;
const ScanError = types.ScanError;

/// Builds a compact JSON array from a list of element spans.
///
/// Slices each element from the original buffer, strips insignificant
/// whitespace by writing byte-by-byte (only for non-compact inputs).
/// For compact inputs, slices are written directly.
pub fn buildCompactArray(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    element_spans: []const Span,
    is_compact: bool,
) ![]u8 {
    std.debug.assert(buffer.len > 0);

    var output = std.ArrayList(u8){};
    errdefer output.deinit(allocator);

    try output.append(allocator, '[');

    for (element_spans, 0..) |span, index| {
        if (index > 0) {
            try output.append(allocator, ',');
        }
        std.debug.assert(span.end >= span.start);
        if (is_compact) {
            try output.appendSlice(allocator, span.slice(buffer));
        } else {
            try appendCompact(allocator, &output, span.slice(buffer));
        }
    }

    try output.append(allocator, ']');
    return output.toOwnedSlice(allocator);
}

/// Builds a compact JSON object from a list of key-value element pairs.
///
/// Each Element contains a key_span and value_span. The output is
/// {"key1":value1,"key2":value2,...} with no insignificant whitespace.
pub fn buildCompactObject(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    elements: []const types.Element,
    is_compact: bool,
) ![]u8 {
    std.debug.assert(buffer.len > 0);

    var output = std.ArrayList(u8){};
    errdefer output.deinit(allocator);

    try output.append(allocator, '{');

    for (elements, 0..) |element, index| {
        if (index > 0) {
            try output.append(allocator, ',');
        }
        std.debug.assert(element.key_span.end >= element.key_span.start);
        std.debug.assert(element.value_span.end >= element.value_span.start);
        if (is_compact) {
            try output.appendSlice(allocator, element.key_span.slice(buffer));
            try output.append(allocator, ':');
            try output.appendSlice(allocator, element.value_span.slice(buffer));
        } else {
            try appendCompact(allocator, &output, element.key_span.slice(buffer));
            try output.append(allocator, ':');
            try appendCompact(allocator, &output, element.value_span.slice(buffer));
        }
    }

    try output.append(allocator, '}');
    return output.toOwnedSlice(allocator);
}

/// Appends a JSON value slice to the output, stripping insignificant whitespace.
///
/// Tracks whether the current position is inside a string to preserve
/// literal spaces within string values. Escape sequences are passed through
/// unchanged.
fn appendCompact(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    data: []const u8,
) !void {
    var inside_string: bool = false;
    var cursor: usize = 0;

    while (cursor < data.len) {
        const byte = data[cursor];

        if (inside_string) {
            try output.append(allocator, byte);
            if (byte == '"') {
                inside_string = false;
            } else if (byte == '\\') {
                cursor += 1;
                if (cursor < data.len) {
                    try output.append(allocator, data[cursor]);
                    if (data[cursor] == 'u') {
                        // \uXXXX: copy 4 hex digits.
                        const remaining = @min(@as(usize, 4), data.len - cursor - 1);
                        for (data[cursor + 1 ..][0..remaining]) |hex_byte| {
                            try output.append(allocator, hex_byte);
                        }
                        cursor += 1 + remaining;
                        continue;
                    }
                }
            }
            cursor += 1;
            continue;
        }

        switch (byte) {
            ' ', '\t', '\n', '\r' => {
                cursor += 1;
            },
            '"' => {
                inside_string = true;
                try output.append(allocator, byte);
                cursor += 1;
            },
            else => {
                try output.append(allocator, byte);
                cursor += 1;
            },
        }
    }
}
