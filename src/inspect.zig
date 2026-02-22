//! chunker_inspect implementation.
//!
//! Examines a JSON file's structure: root type, element count, key listing
//! (for objects), average element size, and chunk count at a given chunk_size.
//! This is O(total_bytes) because compactSize must walk all values.
const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
const scanner_strings = @import("scanner_strings.zig");

const Pos = types.Pos;
const Span = types.Span;
const ValueType = types.ValueType;
const ScanError = types.ScanError;
const Element = types.Element;

/// Result of an inspect operation.
pub const InspectResult = struct {
    file_path: []const u8,
    file_size: u64,
    value_type: ValueType,
    element_count: u32,
    average_size: u32,
    keys: [][]const u8,
    chunk_count: u32,
    chunk_size: u32,
    is_compact: bool,
};

/// Inspect error set.
pub const InspectError = ScanError || error{
    OutOfMemory,
    ObjectTooLarge,
};

/// Inspects the structure of a JSON buffer.
///
/// Returns metadata about the root value: type, element count, keys (for
/// objects), chunk count, and average element size. The chunk_size parameter
/// controls how chunks are estimated.
pub fn inspect(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    file_path: []const u8,
    file_size: u64,
    chunk_size: u32,
) InspectError!InspectResult {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(chunk_size >= config.min_chunk_size);

    const root_span = scanner.scanValue(buffer) catch |err| return err;
    const value_type = scanner.classifyValue(buffer, root_span.start) catch |err| return err;

    // Detect if the file is compact (no insignificant whitespace at top level).
    const is_compact = detectCompact(buffer, root_span);

    switch (value_type) {
        .array => return inspectArray(allocator, buffer, root_span, file_path, file_size, chunk_size, is_compact),
        .object => return inspectObject(allocator, buffer, root_span, file_path, file_size, chunk_size, is_compact),
        else => return inspectScalar(buffer, root_span, value_type, file_path, file_size, chunk_size, is_compact),
    }
}

/// Detects whether the buffer contains compact JSON (no insignificant
/// whitespace between structural tokens at the top level).
fn detectCompact(buffer: []const u8, root_span: Span) bool {
    const data = root_span.slice(buffer);
    var inside_string: bool = false;
    for (data) |byte| {
        if (inside_string) {
            if (byte == '"') {
                inside_string = false;
            } else if (byte == '\\') {
                // Skip next byte (escape).
                inside_string = true;
                continue;
            }
            continue;
        }
        switch (byte) {
            ' ', '\t', '\n', '\r' => return false,
            '"' => inside_string = true,
            else => {},
        }
    }
    return true;
}

/// Inspect a scalar value (string, number, bool, null).
fn inspectScalar(
    buffer: []const u8,
    root_span: Span,
    value_type: ValueType,
    file_path: []const u8,
    file_size: u64,
    chunk_size: u32,
    is_compact: bool,
) InspectError!InspectResult {
    std.debug.assert(root_span.end > root_span.start);

    const size = if (is_compact) root_span.len() else (scanner.compactSize(buffer, root_span) catch |err| return err);

    return InspectResult{
        .file_path = file_path,
        .file_size = file_size,
        .value_type = value_type,
        .element_count = 1,
        .average_size = size,
        .keys = &[_][]const u8{},
        .chunk_count = 1,
        .chunk_size = chunk_size,
        .is_compact = is_compact,
    };
}

/// Inspect an array: count elements, compute average size, estimate chunks.
fn inspectArray(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    root_span: Span,
    file_path: []const u8,
    file_size: u64,
    chunk_size: u32,
    is_compact: bool,
) InspectError!InspectResult {
    _ = allocator;
    std.debug.assert(buffer[root_span.start] == '[');

    var iterator = scanner.TopLevelIterator.init(buffer, root_span.start) catch |err| return err;

    var element_count: u32 = 0;
    var total_compact_size: u64 = 0;
    var chunk_count: u32 = 1;
    var running_size: u32 = 0;

    while (true) {
        const element_opt = iterator.next() catch |err| return err;
        const element = element_opt orelse break;

        const element_size = if (is_compact)
            element.len()
        else
            (scanner.compactSize(buffer, element) catch |err| return err);

        element_count += 1;
        total_compact_size += element_size;

        // Chunk accumulation.
        var element_cost = element_size;
        if (running_size > 0) {
            element_cost += 1; // comma
        }
        if (running_size + element_cost > chunk_size and running_size > 0) {
            chunk_count += 1;
            running_size = element_size;
        } else {
            running_size += element_cost;
        }
    }

    // Empty array: 1 chunk (empty).
    if (element_count == 0) {
        chunk_count = 1;
    }

    const average_size: u32 = if (element_count > 0)
        @intCast(total_compact_size / element_count)
    else
        0;

    return InspectResult{
        .file_path = file_path,
        .file_size = file_size,
        .value_type = .array,
        .element_count = element_count,
        .average_size = average_size,
        .keys = &[_][]const u8{},
        .chunk_count = chunk_count,
        .chunk_size = chunk_size,
        .is_compact = is_compact,
    };
}

/// Inspect an object: count pairs, list keys, compute average size,
/// estimate chunks using sorted key order.
fn inspectObject(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    root_span: Span,
    file_path: []const u8,
    file_size: u64,
    chunk_size: u32,
    is_compact: bool,
) InspectError!InspectResult {
    std.debug.assert(buffer[root_span.start] == '{');

    // First pass: count pairs.
    var count_iterator = scanner.TopLevelIterator.init(buffer, root_span.start) catch |err| return err;
    var pair_count: u32 = 0;
    while (true) {
        const element_opt = count_iterator.next() catch |err| return err;
        if (element_opt == null) break;
        pair_count += 1;
    }

    if (pair_count > config.max_object_keys) return error.ObjectTooLarge;

    if (pair_count == 0) {
        return emptyObjectResult(file_path, file_size, chunk_size, is_compact);
    }

    // Allocate pair buffer and key list.
    var elements = try allocator.alloc(Element, pair_count);
    defer allocator.free(elements);

    var keys = try allocator.alloc([]const u8, pair_count);
    errdefer allocator.free(keys);

    // Second pass: collect pairs.
    try collectObjectPairs(buffer, root_span, elements, keys, pair_count);

    // Sort by key text.
    const sort_ctx = SortContext{ .buffer = buffer };
    std.sort.pdq(Element, elements[0..pair_count], sort_ctx, SortContext.lessThan);
    std.sort.pdq([]const u8, keys[0..pair_count], {}, keysLessThan);

    // Compute chunk count and total size.
    const stats = try computeObjectChunks(buffer, elements[0..pair_count], chunk_size, is_compact);

    const average_size: u32 = if (pair_count > 0)
        @intCast(stats.total_compact_size / pair_count)
    else
        0;

    return InspectResult{
        .file_path = file_path,
        .file_size = file_size,
        .value_type = .object,
        .element_count = pair_count,
        .average_size = average_size,
        .keys = keys,
        .chunk_count = stats.chunk_count,
        .chunk_size = chunk_size,
        .is_compact = is_compact,
    };
}

/// Returns an InspectResult for an empty object.
fn emptyObjectResult(
    file_path: []const u8,
    file_size: u64,
    chunk_size: u32,
    is_compact: bool,
) InspectResult {
    return InspectResult{
        .file_path = file_path,
        .file_size = file_size,
        .value_type = .object,
        .element_count = 0,
        .average_size = 0,
        .keys = &[_][]const u8{},
        .chunk_count = 1,
        .chunk_size = chunk_size,
        .is_compact = is_compact,
    };
}

/// Collects key/value Element pairs from an object via a second-pass iteration.
fn collectObjectPairs(
    buffer: []const u8,
    root_span: Span,
    elements: []Element,
    keys: [][]const u8,
    pair_count: u32,
) InspectError!void {
    var collect_iterator = scanner.TopLevelIterator.init(buffer, root_span.start) catch |err| return err;
    var index: u32 = 0;

    while (index < pair_count) {
        const element_span = (collect_iterator.next() catch |err| return err) orelse break;

        var cursor = scanner.skipWhitespace(buffer, element_span.start);
        const key_start = cursor;
        const key_end = scanner_strings.skipString(buffer, cursor) catch |err| return err;
        cursor = scanner.skipWhitespace(buffer, key_end);
        if (cursor < buffer.len and buffer[cursor] == ':') cursor += 1;
        cursor = scanner.skipWhitespace(buffer, cursor);
        const value_start = cursor;
        const value_end = scanner.skipValue(buffer, cursor) catch |err| return err;

        elements[index] = Element{
            .key_span = Span{ .start = key_start, .end = key_end },
            .value_span = Span{ .start = value_start, .end = value_end },
        };
        keys[index] = buffer[key_start + 1 .. key_end - 1];
        index += 1;
    }
}

/// Chunk estimation stats for objects.
const ObjectChunkStats = struct {
    chunk_count: u32,
    total_compact_size: u64,
};

/// Computes chunk count and total compact size for sorted object elements.
fn computeObjectChunks(
    buffer: []const u8,
    elements: []const Element,
    chunk_size: u32,
    is_compact: bool,
) InspectError!ObjectChunkStats {
    var total_compact_size: u64 = 0;
    var chunk_count: u32 = 1;
    var running_size: u32 = 0;

    for (elements) |element| {
        const key_size = if (is_compact)
            element.key_span.len()
        else
            (scanner.compactSize(buffer, element.key_span) catch |err| return err);
        const value_size = if (is_compact)
            element.value_span.len()
        else
            (scanner.compactSize(buffer, element.value_span) catch |err| return err);

        const pair_base_cost = key_size + value_size + 1; // colon
        total_compact_size += pair_base_cost;

        var pair_cost = pair_base_cost;
        if (running_size > 0) pair_cost += 1; // comma
        if (running_size + pair_cost > chunk_size and running_size > 0) {
            chunk_count += 1;
            running_size = pair_base_cost;
        } else {
            running_size += pair_cost;
        }
    }

    return ObjectChunkStats{
        .chunk_count = chunk_count,
        .total_compact_size = total_compact_size,
    };
}

/// Comparator for sorting key name slices alphabetically.
fn keysLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Sort context for sorting Element pairs by raw key bytes.
const SortContext = struct {
    buffer: []const u8,

    pub fn lessThan(ctx: SortContext, a: Element, b: Element) bool {
        // Compare raw key bytes between quotes.
        const a_key = ctx.buffer[a.key_span.start + 1 .. a.key_span.end - 1];
        const b_key = ctx.buffer[b.key_span.start + 1 .. b.key_span.end - 1];
        return std.mem.lessThan(u8, a_key, b_key);
    }
};
