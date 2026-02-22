//! Unit tests for scanner.zig: value scanning, classification, whitespace, numbers,
//! literals, containers, bracket matching, depth limits, and compactSize.
const std = @import("std");
const chunker = @import("chunker");
const scanner = chunker.scanner;
const types = chunker.types;
const ScanError = types.ScanError;
const Span = types.Span;
const Pos = types.Pos;

// -- scanValue tests (top-level entry) --

test "scanValue - simple array" {
    const buffer = "[1,2,3]";
    const span = try scanner.scanValue(buffer);
    try std.testing.expectEqual(@as(Pos, 0), span.start);
    try std.testing.expectEqual(@as(Pos, 7), span.end);
}

test "scanValue - with leading whitespace" {
    const buffer = "  [1]  ";
    const span = try scanner.scanValue(buffer);
    try std.testing.expectEqual(@as(Pos, 2), span.start);
    try std.testing.expectEqual(@as(Pos, 5), span.end);
}

test "scanValue - trailing content rejected" {
    const buffer = "[1,2,3] garbage";
    const result = scanner.scanValue(buffer);
    try std.testing.expectError(ScanError.TrailingContent, result);
}

test "scanValue - whitespace-only buffer" {
    // scanValue asserts buffer.len > 0, so calling it on empty buffer
    // would be a programming error. We test with whitespace-only instead.
    const ws_buffer = "   ";
    const result = scanner.scanValue(ws_buffer);
    try std.testing.expectError(ScanError.UnexpectedEndOfInput, result);
}

test "scanValue - string value" {
    const buffer = "\"hello\"";
    const span = try scanner.scanValue(buffer);
    try std.testing.expectEqual(@as(Pos, 0), span.start);
    try std.testing.expectEqual(@as(Pos, 7), span.end);
}

test "scanValue - number value" {
    const buffer = "42";
    const span = try scanner.scanValue(buffer);
    try std.testing.expectEqual(@as(Pos, 0), span.start);
    try std.testing.expectEqual(@as(Pos, 2), span.end);
}

test "scanValue - true literal" {
    const buffer = "true";
    const span = try scanner.scanValue(buffer);
    try std.testing.expectEqual(@as(Pos, 0), span.start);
    try std.testing.expectEqual(@as(Pos, 4), span.end);
}

test "scanValue - false literal" {
    const buffer = "false";
    const span = try scanner.scanValue(buffer);
    try std.testing.expectEqual(@as(Pos, 0), span.start);
    try std.testing.expectEqual(@as(Pos, 5), span.end);
}

test "scanValue - null literal" {
    const buffer = "null";
    const span = try scanner.scanValue(buffer);
    try std.testing.expectEqual(@as(Pos, 0), span.start);
    try std.testing.expectEqual(@as(Pos, 4), span.end);
}

test "scanValue - nested object" {
    const buffer = "{\"a\":{\"b\":1}}";
    const span = try scanner.scanValue(buffer);
    try std.testing.expectEqual(@as(Pos, 0), span.start);
    try std.testing.expectEqual(@as(Pos, @intCast(buffer.len)), span.end);
}

// -- classifyValue tests --

test "classifyValue - all types" {
    try std.testing.expectEqual(types.ValueType.string, try scanner.classifyValue("\"x\"", 0));
    try std.testing.expectEqual(types.ValueType.object, try scanner.classifyValue("{}", 0));
    try std.testing.expectEqual(types.ValueType.array, try scanner.classifyValue("[]", 0));
    try std.testing.expectEqual(types.ValueType.boolean, try scanner.classifyValue("true", 0));
    try std.testing.expectEqual(types.ValueType.boolean, try scanner.classifyValue("false", 0));
    try std.testing.expectEqual(types.ValueType.null_type, try scanner.classifyValue("null", 0));
    try std.testing.expectEqual(types.ValueType.number, try scanner.classifyValue("42", 0));
    try std.testing.expectEqual(types.ValueType.number, try scanner.classifyValue("-1", 0));
}

test "classifyValue - invalid byte" {
    const result = scanner.classifyValue("xyz", 0);
    try std.testing.expectError(ScanError.UnexpectedByte, result);
}

// -- skipWhitespace tests --

test "skipWhitespace - all whitespace types" {
    const buffer = " \t\n\rx";
    const pos = scanner.skipWhitespace(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 4), pos);
}

test "skipWhitespace - no whitespace" {
    const buffer = "abc";
    const pos = scanner.skipWhitespace(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 0), pos);
}

test "skipWhitespace - all whitespace returns buffer.len" {
    const buffer = "   ";
    const pos = scanner.skipWhitespace(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 3), pos);
}

// -- skipNumber tests --

test "skipNumber - integer" {
    const buffer = "42";
    const end = try scanner.skipNumber(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 2), end);
}

test "skipNumber - zero" {
    const buffer = "0";
    const end = try scanner.skipNumber(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 1), end);
}

test "skipNumber - negative" {
    const buffer = "-1";
    const end = try scanner.skipNumber(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 2), end);
}

test "skipNumber - decimal" {
    const buffer = "1.5";
    const end = try scanner.skipNumber(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 3), end);
}

test "skipNumber - exponent" {
    const buffer = "1e10";
    const end = try scanner.skipNumber(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 4), end);
}

test "skipNumber - negative exponent" {
    const buffer = "1.5E-3";
    const end = try scanner.skipNumber(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 6), end);
}

test "skipNumber - positive exponent sign" {
    const buffer = "1e+10";
    const end = try scanner.skipNumber(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 5), end);
}

test "skipNumber - reject leading zeros (007)" {
    const buffer = "007";
    const result = scanner.skipNumber(buffer, 0);
    try std.testing.expectError(ScanError.InvalidNumber, result);
}

test "skipNumber - reject trailing dot (1.)" {
    const buffer = "1.x";
    const result = scanner.skipNumber(buffer, 0);
    try std.testing.expectError(ScanError.InvalidNumber, result);
}

test "skipNumber - reject leading dot (.5)" {
    const buffer = ".5";
    const result = scanner.skipNumber(buffer, 0);
    try std.testing.expectError(ScanError.InvalidNumber, result);
}

test "skipNumber - reject empty exponent (1e)" {
    const buffer = "1e";
    const result = scanner.skipNumber(buffer, 0);
    try std.testing.expectError(ScanError.UnexpectedEndOfInput, result);
}

test "skipNumber - reject exponent with no digits (1e+)" {
    const buffer = "1e+";
    const result = scanner.skipNumber(buffer, 0);
    try std.testing.expectError(ScanError.UnexpectedEndOfInput, result);
}

test "skipNumber - number followed by comma" {
    const buffer = "42,";
    const end = try scanner.skipNumber(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 2), end);
}

test "skipNumber - bare minus rejected" {
    const buffer = "-";
    const result = scanner.skipNumber(buffer, 0);
    try std.testing.expectError(ScanError.UnexpectedEndOfInput, result);
}

// -- skipLiteral tests --

test "skipLiteral - true" {
    const buffer = "true";
    const end = try scanner.skipLiteral(buffer, 0, "true");
    try std.testing.expectEqual(@as(Pos, 4), end);
}

test "skipLiteral - false" {
    const buffer = "false";
    const end = try scanner.skipLiteral(buffer, 0, "false");
    try std.testing.expectEqual(@as(Pos, 5), end);
}

test "skipLiteral - null" {
    const buffer = "null";
    const end = try scanner.skipLiteral(buffer, 0, "null");
    try std.testing.expectEqual(@as(Pos, 4), end);
}

test "skipLiteral - truncated" {
    const buffer = "tru";
    const result = scanner.skipLiteral(buffer, 0, "true");
    try std.testing.expectError(ScanError.UnexpectedEndOfInput, result);
}

test "skipLiteral - misspelled" {
    const buffer = "trie";
    const result = scanner.skipLiteral(buffer, 0, "true");
    try std.testing.expectError(ScanError.InvalidLiteral, result);
}

// -- skipValue tests (container dispatch) --

test "skipValue - empty array" {
    const buffer = "[]";
    const end = try scanner.skipValue(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 2), end);
}

test "skipValue - empty object" {
    const buffer = "{}";
    const end = try scanner.skipValue(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 2), end);
}

test "skipValue - nested array" {
    const buffer = "[[1],[2,[3]]]";
    const end = try scanner.skipValue(buffer, 0);
    try std.testing.expectEqual(@as(Pos, @intCast(buffer.len)), end);
}

test "skipValue - object with mixed values" {
    const buffer = "{\"a\":1,\"b\":\"c\",\"d\":true,\"e\":null}";
    const end = try scanner.skipValue(buffer, 0);
    try std.testing.expectEqual(@as(Pos, @intCast(buffer.len)), end);
}

test "skipValue - mismatched bracket [}" {
    const buffer = "[}";
    const result = scanner.skipValue(buffer, 0);
    try std.testing.expectError(ScanError.MismatchedBracket, result);
}

test "skipValue - mismatched bracket {]" {
    const buffer = "{]";
    const result = scanner.skipValue(buffer, 0);
    try std.testing.expectError(ScanError.MismatchedBracket, result);
}

test "skipValue - unclosed array" {
    const buffer = "[1,2";
    const result = scanner.skipValue(buffer, 0);
    try std.testing.expectError(ScanError.UnexpectedEndOfInput, result);
}

test "skipValue - unclosed object" {
    const buffer = "{\"a\":1";
    const result = scanner.skipValue(buffer, 0);
    try std.testing.expectError(ScanError.UnexpectedEndOfInput, result);
}

test "skipValue - closing bracket is last byte" {
    const buffer = "[1]";
    const end = try scanner.skipValue(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 3), end);
    try std.testing.expectEqual(buffer.len, end);
}

test "skipValue - string dispatches correctly" {
    const buffer = "\"test\"";
    const end = try scanner.skipValue(buffer, 0);
    try std.testing.expectEqual(@as(Pos, 6), end);
}

test "skipValue - invalid start byte" {
    const buffer = "xyz";
    const result = scanner.skipValue(buffer, 0);
    try std.testing.expectError(ScanError.UnexpectedByte, result);
}

// -- Container: pretty-printed JSON --

test "skipValue - pretty-printed array" {
    const buffer = "[\n  1,\n  2,\n  3\n]";
    const end = try scanner.skipValue(buffer, 0);
    try std.testing.expectEqual(@as(Pos, @intCast(buffer.len)), end);
}

test "skipValue - pretty-printed object" {
    const buffer = "{\n  \"a\": 1,\n  \"b\": 2\n}";
    const end = try scanner.skipValue(buffer, 0);
    try std.testing.expectEqual(@as(Pos, @intCast(buffer.len)), end);
}

// -- compactSize tests --

test "compactSize - string" {
    const buffer = "\"hello\"";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    try std.testing.expectEqual(@as(u32, 7), size);
}

test "compactSize - number" {
    const buffer = "123";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    try std.testing.expectEqual(@as(u32, 3), size);
}

test "compactSize - true" {
    const buffer = "true";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    try std.testing.expectEqual(@as(u32, 4), size);
}

test "compactSize - null" {
    const buffer = "null";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    try std.testing.expectEqual(@as(u32, 4), size);
}

test "compactSize - object with whitespace" {
    const buffer = "{ \"a\" : 1 }";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    // {"a":1} = 7 bytes
    try std.testing.expectEqual(@as(u32, 7), size);
}

test "compactSize - array with whitespace" {
    const buffer = "[ 1 , 2 ]";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    // [1,2] = 5 bytes
    try std.testing.expectEqual(@as(u32, 5), size);
}

test "compactSize - compact input unchanged" {
    const buffer = "{\"a\":1}";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    try std.testing.expectEqual(@as(u32, 7), size);
}

test "compactSize - string with internal spaces preserved" {
    const buffer = "\"hello world\"";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    // "hello world" = 13 bytes (spaces inside string are content, not whitespace)
    try std.testing.expectEqual(@as(u32, 13), size);
}

test "compactSize - pretty-printed nested" {
    const buffer =
        \\{
        \\  "a": [
        \\    1,
        \\    2
        \\  ]
        \\}
    ;
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    // {"a":[1,2]} = 11 bytes
    try std.testing.expectEqual(@as(u32, 11), size);
}

test "compactSize - string with escape sequence" {
    const buffer = "\"a\\nb\"";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    // "a\nb" = 6 bytes raw (quotes + a + \ + n + b)
    try std.testing.expectEqual(@as(u32, 6), size);
}

test "compactSize - string with unicode escape" {
    const buffer = "\"\\u0041\"";
    const span = Span{ .start = 0, .end = @intCast(buffer.len) };
    const size = try scanner.compactSize(buffer, span);
    // "\u0041" = 8 bytes raw (quotes + backslash + u + 4 hex digits)
    try std.testing.expectEqual(@as(u32, 8), size);
}
