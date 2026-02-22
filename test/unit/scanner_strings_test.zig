//! Unit tests for scanner_strings.zig: string skipping, comparison, and content extraction.
const std = @import("std");
const chunker = @import("chunker");
const scanner_strings = chunker.scanner_strings;
const types = chunker.types;
const ScanError = types.ScanError;
const Span = types.Span;

// -- skipString tests --

test "skipString - simple string" {
    const buffer = "\"hello\"";
    const end = try scanner_strings.skipString(buffer, 0);
    try std.testing.expectEqual(@as(types.Pos, 7), end);
}

test "skipString - empty string" {
    const buffer = "\"\"";
    const end = try scanner_strings.skipString(buffer, 0);
    try std.testing.expectEqual(@as(types.Pos, 2), end);
}

test "skipString - string with escaped quote" {
    const buffer = "\"hello\\\"world\"";
    const end = try scanner_strings.skipString(buffer, 0);
    try std.testing.expectEqual(@as(types.Pos, 14), end);
}

test "skipString - string with escaped backslash" {
    const buffer = "\"path\\\\to\"";
    const end = try scanner_strings.skipString(buffer, 0);
    try std.testing.expectEqual(@as(types.Pos, 10), end);
}

test "skipString - all eight escape sequences" {
    const buffer = "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"";
    const end = try scanner_strings.skipString(buffer, 0);
    try std.testing.expectEqual(@as(types.Pos, @intCast(buffer.len)), end);
}

test "skipString - unicode escape" {
    const buffer = "\"\\u0041\"";
    const end = try scanner_strings.skipString(buffer, 0);
    try std.testing.expectEqual(@as(types.Pos, 8), end);
}

test "skipString - unicode escape with lowercase hex" {
    const buffer = "\"\\u00ff\"";
    const end = try scanner_strings.skipString(buffer, 0);
    try std.testing.expectEqual(@as(types.Pos, 8), end);
}

test "skipString - unterminated string" {
    const buffer = "\"hello";
    const result = scanner_strings.skipString(buffer, 0);
    try std.testing.expectError(ScanError.UnexpectedEndOfInput, result);
}

test "skipString - invalid escape" {
    const buffer = "\"\\x\"";
    const result = scanner_strings.skipString(buffer, 0);
    try std.testing.expectError(ScanError.InvalidEscape, result);
}

test "skipString - truncated unicode escape" {
    const buffer = "\"\\u00\"";
    const result = scanner_strings.skipString(buffer, 0);
    try std.testing.expectError(ScanError.InvalidUnicodeEscape, result);
}

test "skipString - invalid hex in unicode escape" {
    const buffer = "\"\\u00GG\"";
    const result = scanner_strings.skipString(buffer, 0);
    try std.testing.expectError(ScanError.InvalidUnicodeEscape, result);
}

test "skipString - unescaped control character" {
    const buffer = "\"hello\x00world\"";
    const result = scanner_strings.skipString(buffer, 0);
    try std.testing.expectError(ScanError.UnexpectedByte, result);
}

test "skipString - escape at end of buffer" {
    const buffer = "\"\\";
    const result = scanner_strings.skipString(buffer, 0);
    try std.testing.expectError(ScanError.UnexpectedEndOfInput, result);
}

test "skipString - closing quote is last byte" {
    const buffer = "\"x\"";
    const end = try scanner_strings.skipString(buffer, 0);
    try std.testing.expectEqual(@as(types.Pos, 3), end);
    // end == buffer.len: critical edge case
    try std.testing.expectEqual(buffer.len, end);
}

// -- stringEquals tests --

test "stringEquals - simple match" {
    const buffer = "\"hello\"";
    const span = Span{ .start = 0, .end = 7 };
    try std.testing.expect(scanner_strings.stringEquals(buffer, span, "hello"));
}

test "stringEquals - no match" {
    const buffer = "\"hello\"";
    const span = Span{ .start = 0, .end = 7 };
    try std.testing.expect(!scanner_strings.stringEquals(buffer, span, "world"));
}

test "stringEquals - empty key matches empty search" {
    const buffer = "\"\"";
    const span = Span{ .start = 0, .end = 2 };
    try std.testing.expect(scanner_strings.stringEquals(buffer, span, ""));
}

test "stringEquals - escaped quote in key" {
    const buffer = "\"say\\\"hi\"";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    try std.testing.expect(scanner_strings.stringEquals(buffer, span, "say\"hi"));
}

test "stringEquals - unicode escape in key" {
    const buffer = "\"\\u0041\"";
    const span = Span{ .start = 0, .end = 8 };
    try std.testing.expect(scanner_strings.stringEquals(buffer, span, "A"));
}

test "stringEquals - prefix mismatch" {
    const buffer = "\"hello\"";
    const span = Span{ .start = 0, .end = 7 };
    try std.testing.expect(!scanner_strings.stringEquals(buffer, span, "helloworld"));
}

test "stringEquals - key longer than search" {
    const buffer = "\"helloworld\"";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    try std.testing.expect(!scanner_strings.stringEquals(buffer, span, "hello"));
}

// -- stringContent tests --

test "stringContent - simple string" {
    const buffer = "\"hello\"";
    const span = Span{ .start = 0, .end = 7 };
    const content = try scanner_strings.stringContent(std.testing.allocator, buffer, span);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello", content);
}

test "stringContent - escaped characters" {
    const buffer = "\"a\\nb\"";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const content = try scanner_strings.stringContent(std.testing.allocator, buffer, span);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("a\nb", content);
}

test "stringContent - unicode escape" {
    const buffer = "\"\\u0041\"";
    const span = Span{ .start = 0, .end = 8 };
    const content = try scanner_strings.stringContent(std.testing.allocator, buffer, span);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("A", content);
}

// -- stringContentLength tests --

test "stringContentLength - simple string" {
    const buffer = "\"hello\"";
    const span = Span{ .start = 0, .end = 7 };
    const length = try scanner_strings.stringContentLength(buffer, span);
    try std.testing.expectEqual(@as(u32, 5), length);
}

test "stringContentLength - escaped characters" {
    const buffer = "\"a\\nb\"";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const length = try scanner_strings.stringContentLength(buffer, span);
    try std.testing.expectEqual(@as(u32, 3), length);
}

test "stringContentLength - unicode escape" {
    const buffer = "\"\\u0041\"";
    const span = Span{ .start = 0, .end = 8 };
    const length = try scanner_strings.stringContentLength(buffer, span);
    try std.testing.expectEqual(@as(u32, 1), length);
}

test "stringContentLength - empty string" {
    const buffer = "\"\"";
    const span = Span{ .start = 0, .end = 2 };
    const length = try scanner_strings.stringContentLength(buffer, span);
    try std.testing.expectEqual(@as(u32, 0), length);
}
