//! chunker_read implementation.
//!
//! Reads a specific chunk of a JSON value, optionally navigating a path first.
//! For arrays and objects, elements are grouped into chunks by compact byte size.
//! Objects are sorted alphabetically by key before chunking.
//! Scalars have exactly one chunk (chunk 0).
const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
const scanner_strings = @import("scanner_strings.zig");
const output_mod = @import("output.zig");
const path_mod = @import("path.zig");

const Pos = types.Pos;
const Span = types.Span;
const ValueType = types.ValueType;
const ScanError = types.ScanError;
const Element = types.Element;

/// Result of a read operation.
pub const ReadResult = struct {
    chunk_index: u32,
    total_chunks: u32,
    bytes_size: u32,
    data: []u8,
};

/// Read error set.
pub const ReadError = ScanError || types.PathError || error{
    OutOfMemory,
    ObjectTooLarge,
    ChunkOutOfRange,
};

/// Reads a chunk from a JSON buffer, optionally navigating a path first.
///
/// If path is empty, operates on the root value. Returns the chunk data
/// as compact JSON, along with chunk index, total chunks, and byte size.
pub fn readChunk(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    path_string: []const u8,
    chunk_index: u32,
    chunk_size: u32,
) ReadError!ReadResult {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(chunk_size >= config.min_chunk_size);

    // Navigate to the target value.
    const target_span = try resolveTarget(buffer, path_string);
    const value_type = scanner.classifyValue(buffer, target_span.start) catch |err| return err;

    switch (value_type) {
        .array => return readArray(allocator, buffer, target_span, chunk_index, chunk_size),
        .object => return readObject(allocator, buffer, target_span, chunk_index, chunk_size),
        else => return readScalar(allocator, buffer, target_span, chunk_index),
    }
}

/// Resolves a path string to a target span in the buffer.
fn resolveTarget(buffer: []const u8, path_string: []const u8) ReadError!Span {
    const root_span = scanner.scanValue(buffer) catch |err| return err;

    if (path_string.len == 0) {
        return root_span;
    }

    const parsed_path = path_mod.parsePath(path_string) catch |err| return err;
    return scanner.navigatePath(
        buffer,
        root_span.start,
        parsed_path.segments[0..parsed_path.length],
    ) catch |err| return err;
}

/// Read a scalar value: only chunk 0 is valid.
fn readScalar(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    target_span: Span,
    chunk_index: u32,
) ReadError!ReadResult {
    std.debug.assert(target_span.end > target_span.start);

    if (chunk_index != 0) {
        return ReadError.ChunkOutOfRange;
    }

    const data = try allocator.dupe(u8, target_span.slice(buffer));
    const compact_bytes = scanner.compactSize(buffer, target_span) catch |err| return err;

    return ReadResult{
        .chunk_index = 0,
        .total_chunks = 1,
        .bytes_size = compact_bytes,
        .data = data,
    };
}

/// Read a chunk from an array.
fn readArray(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    target_span: Span,
    chunk_index: u32,
    chunk_size: u32,
) ReadError!ReadResult {
    std.debug.assert(buffer[target_span.start] == '[');

    var element_spans = std.ArrayList(Span){};
    defer element_spans.deinit(allocator);

    var iterator = scanner.TopLevelIterator.init(buffer, target_span.start) catch |err| return err;
    while (true) {
        const element = (iterator.next() catch |err| return err) orelse break;
        try element_spans.append(allocator, element);
    }

    if (element_spans.items.len == 0) {
        return emptyContainerResult(allocator, chunk_index, "[]");
    }

    var chunk_boundaries = std.ArrayList(u32){};
    defer chunk_boundaries.deinit(allocator);
    try computeArrayChunkBoundaries(buffer, element_spans.items, chunk_size, &chunk_boundaries, allocator);

    const total_chunks: u32 = @intCast(chunk_boundaries.items.len);
    if (chunk_index >= total_chunks) return ReadError.ChunkOutOfRange;

    const chunk_spans = selectChunkRange(Span, element_spans.items, chunk_boundaries.items, chunk_index, total_chunks);

    var bytes_size: u32 = 0;
    for (chunk_spans, 0..) |span, i| {
        bytes_size += scanner.compactSize(buffer, span) catch |err| return err;
        if (i > 0) bytes_size += 1;
    }

    const is_compact = isBufferCompact(buffer, target_span);
    const data = try output_mod.buildCompactArray(allocator, buffer, chunk_spans, is_compact);

    return ReadResult{
        .chunk_index = chunk_index,
        .total_chunks = total_chunks,
        .bytes_size = bytes_size,
        .data = data,
    };
}

/// Read a chunk from an object (sorted by key).
fn readObject(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    target_span: Span,
    chunk_index: u32,
    chunk_size: u32,
) ReadError!ReadResult {
    std.debug.assert(buffer[target_span.start] == '{');

    var elements = std.ArrayList(Element){};
    defer elements.deinit(allocator);
    try collectObjectElements(buffer, target_span, &elements, allocator);

    if (elements.items.len > config.max_object_keys) return ReadError.ObjectTooLarge;

    if (elements.items.len == 0) {
        return emptyContainerResult(allocator, chunk_index, "{}");
    }

    const sort_ctx = SortContext{ .buffer = buffer };
    std.sort.pdq(Element, elements.items, sort_ctx, SortContext.lessThan);

    var chunk_boundaries = std.ArrayList(u32){};
    defer chunk_boundaries.deinit(allocator);
    try computeObjectChunkBoundaries(buffer, elements.items, chunk_size, &chunk_boundaries, allocator);

    const total_chunks: u32 = @intCast(chunk_boundaries.items.len);
    if (chunk_index >= total_chunks) return ReadError.ChunkOutOfRange;

    const chunk_elements = selectChunkRange(Element, elements.items, chunk_boundaries.items, chunk_index, total_chunks);

    var bytes_size: u32 = 0;
    for (chunk_elements, 0..) |element, i| {
        bytes_size += scanner.compactSize(buffer, element.key_span) catch |err| return err;
        bytes_size += scanner.compactSize(buffer, element.value_span) catch |err| return err;
        bytes_size += 1; // colon
        if (i > 0) bytes_size += 1; // comma
    }

    const is_compact = isBufferCompact(buffer, target_span);
    const data = try output_mod.buildCompactObject(allocator, buffer, chunk_elements, is_compact);

    return ReadResult{
        .chunk_index = chunk_index,
        .total_chunks = total_chunks,
        .bytes_size = bytes_size,
        .data = data,
    };
}

/// Returns a ReadResult for an empty container ([] or {}).
fn emptyContainerResult(allocator: std.mem.Allocator, chunk_index: u32, literal: []const u8) ReadError!ReadResult {
    if (chunk_index != 0) return ReadError.ChunkOutOfRange;
    return ReadResult{
        .chunk_index = 0,
        .total_chunks = 1,
        .bytes_size = 0,
        .data = try allocator.dupe(u8, literal),
    };
}

/// Collects key/value Element pairs from an object via iterator.
fn collectObjectElements(
    buffer: []const u8,
    target_span: Span,
    elements: *std.ArrayList(Element),
    allocator: std.mem.Allocator,
) ReadError!void {
    var iterator = scanner.TopLevelIterator.init(buffer, target_span.start) catch |err| return err;
    while (true) {
        const element_span = (iterator.next() catch |err| return err) orelse break;

        var cursor = scanner.skipWhitespace(buffer, element_span.start);
        const key_start = cursor;
        const key_end = scanner_strings.skipString(buffer, cursor) catch |err| return err;
        cursor = scanner.skipWhitespace(buffer, key_end);
        if (cursor < buffer.len and buffer[cursor] == ':') cursor += 1;
        cursor = scanner.skipWhitespace(buffer, cursor);
        const value_start = cursor;
        const value_end = scanner.skipValue(buffer, cursor) catch |err| return err;

        try elements.append(allocator, Element{
            .key_span = Span{ .start = key_start, .end = key_end },
            .value_span = Span{ .start = value_start, .end = value_end },
        });
    }
}

/// Computes chunk boundary indices for array elements by compact size.
fn computeArrayChunkBoundaries(
    buffer: []const u8,
    spans: []const Span,
    chunk_size: u32,
    boundaries: *std.ArrayList(u32),
    allocator: std.mem.Allocator,
) ReadError!void {
    try boundaries.append(allocator, 0);
    var running_size: u32 = 0;

    for (spans, 0..) |span, index| {
        const element_size = scanner.compactSize(buffer, span) catch |err| return err;
        var element_cost = element_size;
        if (running_size > 0) element_cost += 1;
        if (running_size + element_cost > chunk_size and running_size > 0) {
            try boundaries.append(allocator, @intCast(index));
            running_size = element_size;
        } else {
            running_size += element_cost;
        }
    }
}

/// Computes chunk boundary indices for object elements by compact size.
fn computeObjectChunkBoundaries(
    buffer: []const u8,
    elements: []const Element,
    chunk_size: u32,
    boundaries: *std.ArrayList(u32),
    allocator: std.mem.Allocator,
) ReadError!void {
    try boundaries.append(allocator, 0);
    var running_size: u32 = 0;

    for (elements, 0..) |element, index| {
        const key_size = scanner.compactSize(buffer, element.key_span) catch |err| return err;
        const value_size = scanner.compactSize(buffer, element.value_span) catch |err| return err;
        const pair_base_cost = key_size + value_size + 1;

        var pair_cost = pair_base_cost;
        if (running_size > 0) pair_cost += 1;
        if (running_size + pair_cost > chunk_size and running_size > 0) {
            try boundaries.append(allocator, @intCast(index));
            running_size = pair_base_cost;
        } else {
            running_size += pair_cost;
        }
    }
}

/// Selects the element range for a given chunk index.
fn selectChunkRange(
    comptime T: type,
    items: []const T,
    boundaries: []const u32,
    chunk_index: u32,
    total_chunks: u32,
) []const T {
    const start = boundaries[chunk_index];
    const end: u32 = if (chunk_index + 1 < total_chunks)
        boundaries[chunk_index + 1]
    else
        @intCast(items.len);
    return items[start..end];
}

/// Quick check: is this span compact (no insignificant whitespace)?
fn isBufferCompact(buffer: []const u8, span: Span) bool {
    const data = span.slice(buffer);
    var inside_string: bool = false;
    for (data) |byte| {
        if (inside_string) {
            if (byte == '"') inside_string = false;
            if (byte == '\\') {
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

/// Sort context for sorting Element pairs by raw key bytes.
const SortContext = struct {
    buffer: []const u8,

    pub fn lessThan(ctx: SortContext, a: Element, b: Element) bool {
        const a_key = ctx.buffer[a.key_span.start + 1 .. a.key_span.end - 1];
        const b_key = ctx.buffer[b.key_span.start + 1 .. b.key_span.end - 1];
        return std.mem.lessThan(u8, a_key, b_key);
    }
};
