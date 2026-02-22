//! Dot-notation path parser for JSON navigation.
//!
//! Parses path strings like "users[0].name" into stack-allocated segments.
//! Zero allocation -- all segments reference slices of the original path string.
//! Valid segment characters: any UTF-8 byte except '.' and '['.
//! No escaping mechanism: keys containing literal '.' or '[' are not addressable.
const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");

const PathSegment = types.PathSegment;
const PathBuf = types.PathBuf;
const PathError = types.PathError;

/// Parses a dot-notation path string into a stack-allocated PathBuf.
///
/// Examples:
///   "" -> empty PathBuf (root value)
///   "name" -> [key("name")]
///   "users[0].name" -> [key("users"), index(0), key("name")]
///   "[0]" -> [index(0)]
///   "a.b.c" -> [key("a"), key("b"), key("c")]
pub fn parsePath(path: []const u8) PathError!PathBuf {
    var result = PathBuf{
        .segments = undefined,
        .length = 0,
    };

    if (path.len == 0) {
        std.debug.assert(result.length == 0);
        return result;
    }

    var cursor: usize = 0;

    while (cursor < path.len) {
        if (result.length >= config.max_path_segments) return PathError.TooManySegments;

        if (path[cursor] == '[') {
            cursor = try parseIndexSegment(path, cursor, &result);
        } else {
            cursor = try parseKeySegment(path, cursor, &result);
        }
    }

    std.debug.assert(result.length > 0);
    return result;
}

/// Parses an array index segment "[N]" starting at the '[' character.
/// Returns the cursor position after the segment.
fn parseIndexSegment(path: []const u8, start: usize, result: *PathBuf) PathError!usize {
    var cursor = start + 1;
    const index_start = cursor;
    while (cursor < path.len and path[cursor] != ']') cursor += 1;
    if (cursor >= path.len) return PathError.InvalidIndex;

    const index_str = path[index_start..cursor];
    if (index_str.len == 0) return PathError.InvalidIndex;

    const index_value = std.fmt.parseInt(u32, index_str, 10) catch return PathError.InvalidIndex;
    result.segments[result.length] = PathSegment{ .index = index_value };
    result.length += 1;
    cursor += 1; // skip ']'

    // Skip optional dot after ']'.
    if (cursor < path.len and path[cursor] == '.') cursor += 1;
    return cursor;
}

/// Parses a key segment (everything until '.' or '[').
/// Returns the cursor position after the segment.
fn parseKeySegment(path: []const u8, start: usize, result: *PathBuf) PathError!usize {
    var cursor = start;
    while (cursor < path.len and path[cursor] != '.' and path[cursor] != '[') cursor += 1;

    const key_str = path[start..cursor];
    if (key_str.len == 0) return PathError.EmptySegment;

    result.segments[result.length] = PathSegment{ .key = key_str };
    result.length += 1;

    // Skip the dot separator if present.
    if (cursor < path.len and path[cursor] == '.') {
        cursor += 1;
        if (cursor >= path.len or path[cursor] == '.') return PathError.EmptySegment;
    }
    return cursor;
}
