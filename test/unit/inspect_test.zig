//! Unit tests for inspect.zig: file structure inspection.
const std = @import("std");
const chunker = @import("chunker");
const inspect_mod = chunker.inspect;

test "inspect - simple array" {
    const buffer = "[1,2,3]";
    const result = try inspect_mod.inspect(std.testing.allocator, buffer, "test.json", 7, 100);
    defer std.testing.allocator.free(result.keys);

    try std.testing.expectEqual(chunker.types.ValueType.array, result.value_type);
    try std.testing.expectEqual(@as(u32, 3), result.element_count);
    try std.testing.expectEqual(@as(u32, 1), result.chunk_count);
    try std.testing.expect(result.is_compact);
}

test "inspect - array with small chunk size" {
    const buffer = "[1,2,3]";
    // chunk_size = 2: each element is 1 byte, so "1" fits, then "2" fits alone, "3" alone
    // Element 0: size=1, running=1
    // Element 1: cost=1+1(comma)=2, running+cost=3>2, new chunk. running=1
    // Element 2: cost=1+1(comma)=2, running+cost=3>2, new chunk. running=1
    const result = try inspect_mod.inspect(std.testing.allocator, buffer, "test.json", 7, 2);
    defer std.testing.allocator.free(result.keys);

    try std.testing.expectEqual(@as(u32, 3), result.chunk_count);
}

test "inspect - empty array" {
    const buffer = "[]";
    const result = try inspect_mod.inspect(std.testing.allocator, buffer, "test.json", 2, 100);
    defer std.testing.allocator.free(result.keys);

    try std.testing.expectEqual(@as(u32, 0), result.element_count);
    try std.testing.expectEqual(@as(u32, 1), result.chunk_count);
}

test "inspect - simple object" {
    const buffer = "{\"b\":2,\"a\":1}";
    const result = try inspect_mod.inspect(std.testing.allocator, buffer, "test.json", 13, 100);
    defer std.testing.allocator.free(result.keys);

    try std.testing.expectEqual(chunker.types.ValueType.object, result.value_type);
    try std.testing.expectEqual(@as(u32, 2), result.element_count);
    try std.testing.expectEqual(@as(u32, 2), result.keys.len);
    // Keys should be sorted alphabetically.
    try std.testing.expectEqualStrings("a", result.keys[0]);
    try std.testing.expectEqualStrings("b", result.keys[1]);
}

test "inspect - empty object" {
    const buffer = "{}";
    const result = try inspect_mod.inspect(std.testing.allocator, buffer, "test.json", 2, 100);
    defer std.testing.allocator.free(result.keys);

    try std.testing.expectEqual(@as(u32, 0), result.element_count);
    try std.testing.expectEqual(@as(u32, 1), result.chunk_count);
}

test "inspect - scalar string" {
    const buffer = "\"hello\"";
    const result = try inspect_mod.inspect(std.testing.allocator, buffer, "test.json", 7, 100);
    defer std.testing.allocator.free(result.keys);

    try std.testing.expectEqual(chunker.types.ValueType.string, result.value_type);
    try std.testing.expectEqual(@as(u32, 1), result.element_count);
    try std.testing.expectEqual(@as(u32, 1), result.chunk_count);
    try std.testing.expectEqual(@as(u32, 7), result.average_size);
}

test "inspect - scalar number" {
    const buffer = "42";
    const result = try inspect_mod.inspect(std.testing.allocator, buffer, "test.json", 2, 100);
    defer std.testing.allocator.free(result.keys);

    try std.testing.expectEqual(chunker.types.ValueType.number, result.value_type);
    try std.testing.expectEqual(@as(u32, 1), result.element_count);
    try std.testing.expectEqual(@as(u32, 2), result.average_size);
}

test "inspect - pretty-printed detects non-compact" {
    const buffer =
        \\{
        \\  "a": 1
        \\}
    ;
    const result = try inspect_mod.inspect(std.testing.allocator, buffer, "test.json", @intCast(buffer.len), 100);
    defer std.testing.allocator.free(result.keys);

    try std.testing.expect(!result.is_compact);
}
