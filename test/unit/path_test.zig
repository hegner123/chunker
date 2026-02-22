//! Unit tests for path.zig: dot-notation path parsing.
//! Also tests scanner navigation functions (navigatePath, objectValueForKey,
//! arrayElementAt, TopLevelIterator).
const std = @import("std");
const chunker = @import("chunker");
const path_mod = chunker.path;
const scanner = chunker.scanner;
const types = chunker.types;
const PathError = types.PathError;
const ScanError = types.ScanError;
const Span = types.Span;
const PathSegment = types.PathSegment;

// -- parsePath tests --

test "parsePath - empty path (root)" {
    const result = try path_mod.parsePath("");
    try std.testing.expectEqual(@as(u16, 0), result.length);
}

test "parsePath - single key" {
    const result = try path_mod.parsePath("name");
    try std.testing.expectEqual(@as(u16, 1), result.length);
    try std.testing.expectEqualStrings("name", result.segments[0].key);
}

test "parsePath - dotted keys" {
    const result = try path_mod.parsePath("a.b.c");
    try std.testing.expectEqual(@as(u16, 3), result.length);
    try std.testing.expectEqualStrings("a", result.segments[0].key);
    try std.testing.expectEqualStrings("b", result.segments[1].key);
    try std.testing.expectEqualStrings("c", result.segments[2].key);
}

test "parsePath - array index" {
    const result = try path_mod.parsePath("[0]");
    try std.testing.expectEqual(@as(u16, 1), result.length);
    try std.testing.expectEqual(@as(u32, 0), result.segments[0].index);
}

test "parsePath - mixed path" {
    const result = try path_mod.parsePath("users[0].name");
    try std.testing.expectEqual(@as(u16, 3), result.length);
    try std.testing.expectEqualStrings("users", result.segments[0].key);
    try std.testing.expectEqual(@as(u32, 0), result.segments[1].index);
    try std.testing.expectEqualStrings("name", result.segments[2].key);
}

test "parsePath - multiple indices" {
    const result = try path_mod.parsePath("data[3].items[0].id");
    try std.testing.expectEqual(@as(u16, 5), result.length);
    try std.testing.expectEqualStrings("data", result.segments[0].key);
    try std.testing.expectEqual(@as(u32, 3), result.segments[1].index);
    try std.testing.expectEqualStrings("items", result.segments[2].key);
    try std.testing.expectEqual(@as(u32, 0), result.segments[3].index);
    try std.testing.expectEqualStrings("id", result.segments[4].key);
}

test "parsePath - empty segment error" {
    const result = path_mod.parsePath("a..b");
    try std.testing.expectError(PathError.EmptySegment, result);
}

test "parsePath - trailing dot error" {
    const result = path_mod.parsePath("a.");
    try std.testing.expectError(PathError.EmptySegment, result);
}

test "parsePath - invalid index" {
    const result = path_mod.parsePath("[abc]");
    try std.testing.expectError(PathError.InvalidIndex, result);
}

test "parsePath - unclosed bracket" {
    const result = path_mod.parsePath("[0");
    try std.testing.expectError(PathError.InvalidIndex, result);
}

test "parsePath - empty bracket" {
    const result = path_mod.parsePath("[]");
    try std.testing.expectError(PathError.InvalidIndex, result);
}

// -- navigatePath tests --

test "navigatePath - object key" {
    const buffer = "{\"name\":\"Alice\"}";
    const parsed = try path_mod.parsePath("name");
    const span = try scanner.navigatePath(buffer, 0, parsed.segments[0..parsed.length]);
    try std.testing.expectEqualStrings("\"Alice\"", span.slice(buffer));
}

test "navigatePath - nested object" {
    const buffer = "{\"a\":{\"b\":42}}";
    const parsed = try path_mod.parsePath("a.b");
    const span = try scanner.navigatePath(buffer, 0, parsed.segments[0..parsed.length]);
    try std.testing.expectEqualStrings("42", span.slice(buffer));
}

test "navigatePath - array index" {
    const buffer = "[10,20,30]";
    const parsed = try path_mod.parsePath("[1]");
    const span = try scanner.navigatePath(buffer, 0, parsed.segments[0..parsed.length]);
    try std.testing.expectEqualStrings("20", span.slice(buffer));
}

test "navigatePath - mixed path" {
    const buffer = "{\"users\":[{\"name\":\"Bob\"}]}";
    const parsed = try path_mod.parsePath("users[0].name");
    const span = try scanner.navigatePath(buffer, 0, parsed.segments[0..parsed.length]);
    try std.testing.expectEqualStrings("\"Bob\"", span.slice(buffer));
}

test "navigatePath - empty path returns root" {
    const buffer = "{\"a\":1}";
    const parsed = try path_mod.parsePath("");
    const span = try scanner.navigatePath(buffer, 0, parsed.segments[0..parsed.length]);
    try std.testing.expectEqualStrings("{\"a\":1}", span.slice(buffer));
}

test "navigatePath - key not found" {
    const buffer = "{\"a\":1}";
    const parsed = try path_mod.parsePath("b");
    const result = scanner.navigatePath(buffer, 0, parsed.segments[0..parsed.length]);
    try std.testing.expectError(PathError.KeyNotFound, result);
}

test "navigatePath - index out of range" {
    const buffer = "[1,2]";
    const parsed = try path_mod.parsePath("[5]");
    const result = scanner.navigatePath(buffer, 0, parsed.segments[0..parsed.length]);
    try std.testing.expectError(PathError.IndexOutOfRange, result);
}

test "navigatePath - not an object" {
    const buffer = "[1,2,3]";
    const parsed = try path_mod.parsePath("key");
    const result = scanner.navigatePath(buffer, 0, parsed.segments[0..parsed.length]);
    try std.testing.expectError(PathError.NotAnObject, result);
}

test "navigatePath - not an array" {
    const buffer = "{\"a\":1}";
    const parsed = try path_mod.parsePath("[0]");
    const result = scanner.navigatePath(buffer, 0, parsed.segments[0..parsed.length]);
    try std.testing.expectError(PathError.NotAnArray, result);
}

test "navigatePath - pretty-printed JSON" {
    const buffer =
        \\{
        \\  "items": [
        \\    "first",
        \\    "second"
        \\  ]
        \\}
    ;
    const parsed = try path_mod.parsePath("items[1]");
    const span = try scanner.navigatePath(buffer, 0, parsed.segments[0..parsed.length]);
    try std.testing.expectEqualStrings("\"second\"", span.slice(buffer));
}

// -- TopLevelIterator tests --

test "TopLevelIterator - array elements" {
    const buffer = "[1,2,3]";
    var iterator = try scanner.TopLevelIterator.init(buffer, 0);

    const first = (try iterator.next()).?;
    try std.testing.expectEqualStrings("1", first.slice(buffer));

    const second = (try iterator.next()).?;
    try std.testing.expectEqualStrings("2", second.slice(buffer));

    const third = (try iterator.next()).?;
    try std.testing.expectEqualStrings("3", third.slice(buffer));

    const done = try iterator.next();
    try std.testing.expect(done == null);
}

test "TopLevelIterator - empty array" {
    const buffer = "[]";
    var iterator = try scanner.TopLevelIterator.init(buffer, 0);
    const done = try iterator.next();
    try std.testing.expect(done == null);
}

test "TopLevelIterator - object elements" {
    const buffer = "{\"a\":1,\"b\":2}";
    var iterator = try scanner.TopLevelIterator.init(buffer, 0);

    const first = (try iterator.next()).?;
    // Object element includes key+colon+value.
    try std.testing.expectEqualStrings("\"a\":1", first.slice(buffer));

    const second = (try iterator.next()).?;
    try std.testing.expectEqualStrings("\"b\":2", second.slice(buffer));

    const done = try iterator.next();
    try std.testing.expect(done == null);
}

test "TopLevelIterator - pretty-printed array" {
    const buffer = "[\n  1,\n  2,\n  3\n]";
    var iterator = try scanner.TopLevelIterator.init(buffer, 0);

    const first = (try iterator.next()).?;
    try std.testing.expectEqualStrings("1", first.slice(buffer));

    const second = (try iterator.next()).?;
    try std.testing.expectEqualStrings("2", second.slice(buffer));

    const third = (try iterator.next()).?;
    try std.testing.expectEqualStrings("3", third.slice(buffer));

    try std.testing.expect((try iterator.next()) == null);
}
