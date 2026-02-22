//! Unit tests for mmap.zig: memory-mapped file I/O.
//!
//! Uses absolute paths to test fixtures. Tests cover:
//! valid files, BOM detection, nonexistent files, and directory rejection.
const std = @import("std");
const chunker = @import("chunker");
const MappedFile = chunker.mmap.MappedFile;
const MmapError = chunker.mmap.MmapError;

const fixture_dir = "/Users/home/Documents/Code/terse-mcp/chunker/test/fixtures/";

test "MappedFile.open - simple array fixture" {
    var mapped = try MappedFile.open(fixture_dir ++ "simple_array.json");
    defer mapped.close();

    const content = mapped.bytes();
    try std.testing.expectEqualStrings("[1,2,3]", content);
    try std.testing.expectEqual(@as(u32, 0), mapped.content_start);
}

test "MappedFile.open - nested fixture" {
    var mapped = try MappedFile.open(fixture_dir ++ "nested.json");
    defer mapped.close();

    const content = mapped.bytes();
    // Just verify it starts and ends correctly.
    try std.testing.expect(content.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), content[0]);
    try std.testing.expectEqual(@as(u8, '}'), content[content.len - 1]);
}

test "MappedFile.open - BOM detection" {
    var mapped = try MappedFile.open(fixture_dir ++ "with_bom.json");
    defer mapped.close();

    // file_size includes the BOM.
    try std.testing.expectEqual(@as(u32, 3), mapped.content_start);

    // bytes() should skip the BOM.
    const content = mapped.bytes();
    try std.testing.expectEqualStrings("{\"bom\":true}", content);
}

test "MappedFile.open - nonexistent file" {
    const result = MappedFile.open(fixture_dir ++ "does_not_exist.json");
    try std.testing.expectError(MmapError.OpenFailed, result);
}

test "MappedFile.open - directory rejected" {
    const result = MappedFile.open("/Users/home/Documents/Code/terse-mcp/chunker/test/fixtures");
    // Opening a directory should fail.
    try std.testing.expect(std.meta.isError(result));
}
