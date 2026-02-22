//! Unit tests for search.zig: key and value searching.
//!
//! Search uses an arena allocator in production (all paths and previews are
//! freed in bulk). Tests wrap std.testing.allocator in an arena to match
//! this pattern and avoid false leak reports from intermediate path strings.
const std = @import("std");
const chunker = @import("chunker");
const search_mod = chunker.search;

test "search - value match in array" {
    const buffer = "[\"hello\",\"world\",\"help\"]";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try search_mod.searchBuffer(
        arena.allocator(),
        buffer,
        null,
        "hel",
        10,
    );

    try std.testing.expectEqual(@as(u32, 2), result.total_found);
    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
}

test "search - key match in object" {
    const buffer = "{\"name\":\"Alice\",\"age\":30,\"nickname\":\"Ali\"}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try search_mod.searchBuffer(
        arena.allocator(),
        buffer,
        "name",
        null,
        10,
    );

    // "name" and "nickname" both contain "name"
    try std.testing.expectEqual(@as(u32, 2), result.total_found);
}

test "search - no matches" {
    const buffer = "{\"a\":1,\"b\":2}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try search_mod.searchBuffer(
        arena.allocator(),
        buffer,
        "xyz",
        null,
        10,
    );

    try std.testing.expectEqual(@as(u32, 0), result.total_found);
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
}

test "search - max results limit" {
    const buffer = "[\"a\",\"a\",\"a\",\"a\",\"a\"]";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try search_mod.searchBuffer(
        arena.allocator(),
        buffer,
        null,
        "a",
        2,
    );

    // total_found counts all, but matches capped at 2.
    try std.testing.expectEqual(@as(u32, 5), result.total_found);
    try std.testing.expectEqual(@as(usize, 2), result.matches.len);
}

test "search - number exact match" {
    const buffer = "[1,10,100]";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try search_mod.searchBuffer(
        arena.allocator(),
        buffer,
        null,
        "1",
        10,
    );

    // Non-string: exact match only. Only "1" matches, not "10" or "100".
    try std.testing.expectEqual(@as(u32, 1), result.total_found);
}

test "search - nested object traversal" {
    const buffer = "{\"users\":[{\"name\":\"Alice\"},{\"name\":\"Bob\"}]}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try search_mod.searchBuffer(
        arena.allocator(),
        buffer,
        null,
        "Alice",
        10,
    );

    try std.testing.expectEqual(@as(u32, 1), result.total_found);
    try std.testing.expectEqualStrings("users[0].name", result.matches[0].path);
}
