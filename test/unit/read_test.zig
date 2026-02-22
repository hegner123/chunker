//! Unit tests for read.zig: chunk reading.
const std = @import("std");
const chunker = @import("chunker");
const read_mod = chunker.read;

test "readChunk - array single chunk" {
    const buffer = "[1,2,3]";
    const result = try read_mod.readChunk(std.testing.allocator, buffer, "", 0, 100);
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqual(@as(u32, 0), result.chunk_index);
    try std.testing.expectEqual(@as(u32, 1), result.total_chunks);
    try std.testing.expectEqualStrings("[1,2,3]", result.data);
}

test "readChunk - array multiple chunks" {
    const buffer = "[1,2,3]";
    // chunk_size = 2: should produce 3 chunks (1 element each)
    const chunk0 = try read_mod.readChunk(std.testing.allocator, buffer, "", 0, 2);
    defer std.testing.allocator.free(chunk0.data);
    try std.testing.expectEqual(@as(u32, 3), chunk0.total_chunks);
    try std.testing.expectEqualStrings("[1]", chunk0.data);

    const chunk1 = try read_mod.readChunk(std.testing.allocator, buffer, "", 1, 2);
    defer std.testing.allocator.free(chunk1.data);
    try std.testing.expectEqualStrings("[2]", chunk1.data);

    const chunk2 = try read_mod.readChunk(std.testing.allocator, buffer, "", 2, 2);
    defer std.testing.allocator.free(chunk2.data);
    try std.testing.expectEqualStrings("[3]", chunk2.data);
}

test "readChunk - array chunk out of range" {
    const buffer = "[1,2,3]";
    const result = read_mod.readChunk(std.testing.allocator, buffer, "", 5, 100);
    try std.testing.expectError(read_mod.ReadError.ChunkOutOfRange, result);
}

test "readChunk - empty array" {
    const buffer = "[]";
    const result = try read_mod.readChunk(std.testing.allocator, buffer, "", 0, 100);
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqual(@as(u32, 1), result.total_chunks);
    try std.testing.expectEqualStrings("[]", result.data);
}

test "readChunk - object sorted by key" {
    const buffer = "{\"b\":2,\"a\":1}";
    const result = try read_mod.readChunk(std.testing.allocator, buffer, "", 0, 100);
    defer std.testing.allocator.free(result.data);

    // Keys should be sorted alphabetically in output.
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":2}", result.data);
}

test "readChunk - scalar passthrough" {
    const buffer = "\"hello\"";
    const result = try read_mod.readChunk(std.testing.allocator, buffer, "", 0, 100);
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqual(@as(u32, 1), result.total_chunks);
    try std.testing.expectEqualStrings("\"hello\"", result.data);
}

test "readChunk - scalar chunk 1 rejected" {
    const buffer = "42";
    const result = read_mod.readChunk(std.testing.allocator, buffer, "", 1, 100);
    try std.testing.expectError(read_mod.ReadError.ChunkOutOfRange, result);
}

test "readChunk - with path navigation" {
    const buffer = "{\"items\":[10,20,30]}";
    const result = try read_mod.readChunk(std.testing.allocator, buffer, "items", 0, 100);
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqualStrings("[10,20,30]", result.data);
}

test "readChunk - pretty-printed array" {
    const buffer = "[\n  1,\n  2,\n  3\n]";
    const result = try read_mod.readChunk(std.testing.allocator, buffer, "", 0, 100);
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqualStrings("[1,2,3]", result.data);
}

test "readChunk - pretty-printed object" {
    const buffer = "{\n  \"b\": 2,\n  \"a\": 1\n}";
    const result = try read_mod.readChunk(std.testing.allocator, buffer, "", 0, 100);
    defer std.testing.allocator.free(result.data);

    try std.testing.expectEqualStrings("{\"a\":1,\"b\":2}", result.data);
}
