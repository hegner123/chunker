//! NDJSON (Newline-Delimited JSON) support for chunker.
//!
//! Provides format detection, line indexing, and NDJSON variants of the
//! four chunker operations (inspect, read, extract, search). Reuses
//! scanner primitives from scanner.zig without modifying that module.
//!
//! Format detection: auto-detect via scanValue. If TrailingContent, check
//! if the first line is a valid JSON value followed by a newline.
//!
//! Path semantics: NDJSON is an implicit array of lines. [N] selects line N.
//! [N].key navigates within line N. Empty path on extract returns an error
//! with guidance; empty path on read packs all lines into byte-budget chunks.
const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
const scanner_strings = @import("scanner_strings.zig");
const path_mod = @import("path.zig");
const output_mod = @import("output.zig");
const search_mod = @import("search.zig");
const read_mod = @import("read.zig");
const extract_mod = @import("extract.zig");

const Pos = types.Pos;
const Span = types.Span;
const ValueType = types.ValueType;
const ScanError = types.ScanError;

/// File format detected by auto-detection.
pub const FileFormat = enum {
    json,
    ndjson,
};

/// Index of NDJSON line boundaries within the mmap buffer.
/// Each entry stores the byte range of a valid JSON value on that line.
pub const NdjsonIndex = struct {
    /// Start positions of JSON values (into mmap buffer).
    line_starts: []Pos,
    /// End positions of JSON values (into mmap buffer).
    line_ends: []Pos,
    /// Number of valid JSON lines found.
    line_count: u32,

    pub fn deinit(self: *NdjsonIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.line_starts);
        allocator.free(self.line_ends);
    }

    /// Returns the span for a specific line.
    pub fn lineSpan(self: *const NdjsonIndex, line: u32) Span {
        std.debug.assert(line < self.line_count);
        return Span{ .start = self.line_starts[line], .end = self.line_ends[line] };
    }
};

/// NDJSON error set.
pub const NdjsonError = ScanError || types.PathError || error{
    OutOfMemory,
    TooManyLines,
    EmptyNdjsonPath,
    InvalidLineIndex,
    ChunkOutOfRange,
    ObjectTooLarge,
};

/// Result of an NDJSON inspect operation.
pub const NdjsonInspectResult = struct {
    file_path: []const u8,
    file_size: u64,
    line_count: u32,
    first_line_type: ValueType,
    sample_keys: [][]const u8,
};

/// Detects whether the buffer contains standard JSON or NDJSON.
///
/// Tries scanValue first. If it succeeds (no TrailingContent), the format
/// is standard JSON. If TrailingContent is returned, checks whether the
/// first value is followed by a newline -- if so, it's NDJSON.
pub fn detectFormat(buffer: []const u8) ScanError!FileFormat {
    std.debug.assert(buffer.len > 0);

    const result = scanner.scanValue(buffer);
    if (result) |_| {
        return .json;
    } else |err| {
        if (err != ScanError.TrailingContent) return err;

        // TrailingContent: check if first line is valid JSON followed by newline.
        const start = scanner.skipWhitespace(buffer, 0);
        if (start >= buffer.len) return ScanError.UnexpectedEndOfInput;

        const value_end = scanner.skipValue(buffer, start) catch |skip_err| return skip_err;

        // After the first value, skip horizontal whitespace only.
        var cursor = value_end;
        while (cursor < buffer.len and (buffer[cursor] == ' ' or buffer[cursor] == '\t')) {
            cursor += 1;
        }
        if (cursor >= buffer.len) return .json;
        if (buffer[cursor] == '\r') cursor += 1;
        if (cursor < buffer.len and buffer[cursor] == '\n') {
            return .ndjson;
        }

        // Not a newline after first value -- genuine trailing content error.
        return ScanError.TrailingContent;
    }
}

/// Builds a line index for an NDJSON buffer.
///
/// O(n) scan: finds each newline, validates each non-empty line contains
/// exactly one JSON value. Empty lines and whitespace-only lines are
/// skipped per NDJSON spec. \r\n line endings handled.
pub fn buildLineIndex(allocator: std.mem.Allocator, buffer: []const u8) NdjsonError!NdjsonIndex {
    std.debug.assert(buffer.len > 0);

    var starts = std.ArrayList(Pos){};
    errdefer starts.deinit(allocator);
    var ends = std.ArrayList(Pos){};
    errdefer ends.deinit(allocator);

    var cursor: Pos = 0;

    while (cursor < buffer.len) {
        // Find end of current line.
        var line_end: Pos = cursor;
        while (line_end < buffer.len and buffer[line_end] != '\n') {
            line_end += 1;
        }

        // Effective end excludes trailing \r.
        var effective_end = line_end;
        if (effective_end > cursor and buffer[effective_end - 1] == '\r') {
            effective_end -= 1;
        }

        // Skip whitespace at start of line.
        const value_start = scanner.skipWhitespace(buffer, cursor);

        if (value_start < effective_end) {
            // Non-empty line: validate it contains a single JSON value.
            const value_end = scanner.skipValue(buffer, value_start) catch |err| return err;

            // Verify only whitespace remains on this line.
            const trailing = scanner.skipWhitespace(buffer, value_end);
            if (trailing < effective_end) {
                return ScanError.TrailingContent;
            }

            if (starts.items.len >= config.max_ndjson_lines) {
                return NdjsonError.TooManyLines;
            }

            try starts.append(allocator, value_start);
            try ends.append(allocator, value_end);
        }

        // Move past the newline.
        cursor = if (line_end < buffer.len) line_end + 1 else line_end;
    }

    const line_count: u32 = @intCast(starts.items.len);

    return NdjsonIndex{
        .line_starts = try starts.toOwnedSlice(allocator),
        .line_ends = try ends.toOwnedSlice(allocator),
        .line_count = line_count,
    };
}

/// NDJSON inspect: reports line count, first line type, and sample keys.
pub fn ndjsonInspect(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    index: *const NdjsonIndex,
    file_path: []const u8,
    file_size: u64,
) NdjsonError!NdjsonInspectResult {
    if (index.line_count == 0) {
        return NdjsonInspectResult{
            .file_path = file_path,
            .file_size = file_size,
            .line_count = 0,
            .first_line_type = .null_type,
            .sample_keys = &[_][]const u8{},
        };
    }

    const first_span = index.lineSpan(0);
    const first_type = scanner.classifyValue(buffer, first_span.start) catch |err| return err;

    // Extract sample keys if first line is an object.
    var keys = std.ArrayList([]const u8){};
    errdefer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }

    if (first_type == .object) {
        try collectObjectKeys(allocator, buffer, first_span, &keys);
    }

    return NdjsonInspectResult{
        .file_path = file_path,
        .file_size = file_size,
        .line_count = index.line_count,
        .first_line_type = first_type,
        .sample_keys = try keys.toOwnedSlice(allocator),
    };
}

/// Collects top-level keys from a JSON object at the given span.
fn collectObjectKeys(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    span: Span,
    keys: *std.ArrayList([]const u8),
) NdjsonError!void {
    std.debug.assert(buffer[span.start] == '{');

    var iterator = scanner.TopLevelIterator.init(buffer, span.start) catch |err| return err;

    while (true) {
        const element_span = (iterator.next() catch |err| return err) orelse break;

        const cursor = scanner.skipWhitespace(buffer, element_span.start);
        if (cursor >= buffer.len or buffer[cursor] != '"') break;

        const key_end = scanner_strings.skipString(buffer, cursor) catch |err| return err;
        const key_text = buffer[cursor + 1 .. key_end - 1];

        try keys.append(allocator, try allocator.dupe(u8, key_text));
    }
}

/// NDJSON read: byte-budget chunking of lines.
///
/// Empty path: all lines treated as array elements, packed into chunks.
/// Path starting with [N]: read line N (further path navigates within).
/// Path starting with a key: error (NDJSON requires line index).
pub fn ndjsonRead(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    index: *const NdjsonIndex,
    path_string: []const u8,
    chunk_index: u32,
    chunk_size: u32,
) NdjsonError!read_mod.ReadResult {
    std.debug.assert(chunk_size >= config.min_chunk_size);

    if (path_string.len == 0) {
        return readAllLines(allocator, buffer, index, chunk_index, chunk_size);
    }

    // Path must start with [N].
    if (path_string[0] != '[') {
        return NdjsonError.EmptyNdjsonPath;
    }

    // Extract line index from [N] prefix.
    const line_info = extractLineIndex(path_string) catch return NdjsonError.EmptyNdjsonPath;

    if (line_info.line_idx >= index.line_count) return NdjsonError.InvalidLineIndex;

    const line_span = index.lineSpan(line_info.line_idx);
    const line_slice = buffer[line_span.start..line_span.end];

    // Delegate to readChunk on the line slice with the remaining path.
    return read_mod.readChunk(allocator, line_slice, line_info.remaining_path, chunk_index, chunk_size);
}

/// Extracts the line index and remaining path from a path string starting with [N].
fn extractLineIndex(path_string: []const u8) error{InvalidIndex}!struct { line_idx: u32, remaining_path: []const u8 } {
    std.debug.assert(path_string.len > 0 and path_string[0] == '[');

    var i: usize = 1;
    while (i < path_string.len and path_string[i] != ']') i += 1;
    if (i >= path_string.len) return error.InvalidIndex;

    const idx_str = path_string[1..i];
    if (idx_str.len == 0) return error.InvalidIndex;

    const line_idx = std.fmt.parseInt(u32, idx_str, 10) catch return error.InvalidIndex;
    i += 1; // skip ']'
    if (i < path_string.len and path_string[i] == '.') i += 1; // skip optional '.'

    return .{ .line_idx = line_idx, .remaining_path = path_string[i..] };
}

/// Packs all NDJSON lines into byte-budget chunks as an array.
fn readAllLines(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    index: *const NdjsonIndex,
    chunk_index: u32,
    chunk_size: u32,
) NdjsonError!read_mod.ReadResult {
    if (index.line_count == 0) {
        if (chunk_index != 0) return NdjsonError.ChunkOutOfRange;
        return read_mod.ReadResult{
            .chunk_index = 0,
            .total_chunks = 1,
            .bytes_size = 0,
            .data = try allocator.dupe(u8, "[]"),
        };
    }

    // Build spans for all lines.
    var line_spans = try allocator.alloc(Span, index.line_count);
    defer allocator.free(line_spans);

    for (0..index.line_count) |i| {
        line_spans[i] = index.lineSpan(@intCast(i));
    }

    // Compute chunk boundaries using byte budget.
    var chunk_boundaries = std.ArrayList(u32){};
    defer chunk_boundaries.deinit(allocator);
    try computeLineChunkBoundaries(buffer, line_spans, chunk_size, &chunk_boundaries, allocator);

    const total_chunks: u32 = @intCast(chunk_boundaries.items.len);
    if (chunk_index >= total_chunks) return NdjsonError.ChunkOutOfRange;

    // Select this chunk's lines.
    const start_idx = chunk_boundaries.items[chunk_index];
    const end_idx: u32 = if (chunk_index + 1 < total_chunks)
        chunk_boundaries.items[chunk_index + 1]
    else
        index.line_count;

    const chunk_spans = line_spans[start_idx..end_idx];

    // Compute bytes_size.
    var bytes_size: u32 = 0;
    for (chunk_spans, 0..) |span, i| {
        bytes_size += scanner.compactSize(buffer, span) catch |err| return err;
        if (i > 0) bytes_size += 1; // comma
    }

    // Build compact array output.
    const data = try output_mod.buildCompactArray(allocator, buffer, chunk_spans, false);

    return read_mod.ReadResult{
        .chunk_index = chunk_index,
        .total_chunks = total_chunks,
        .bytes_size = bytes_size,
        .data = data,
    };
}

/// Computes chunk boundaries for NDJSON lines by compact byte size.
fn computeLineChunkBoundaries(
    buffer: []const u8,
    spans: []const Span,
    chunk_size: u32,
    boundaries: *std.ArrayList(u32),
    allocator: std.mem.Allocator,
) NdjsonError!void {
    try boundaries.append(allocator, 0);
    var running_size: u32 = 0;

    for (spans, 0..) |span, idx| {
        const element_size = scanner.compactSize(buffer, span) catch |err| return err;
        var element_cost = element_size;
        if (running_size > 0) element_cost += 1; // comma
        if (running_size + element_cost > chunk_size and running_size > 0) {
            try boundaries.append(allocator, @intCast(idx));
            running_size = element_size;
        } else {
            running_size += element_cost;
        }
    }
}

/// NDJSON extract: navigate path into specific line, return raw slice.
///
/// Path must start with [N] to select a line. [N] alone returns the
/// whole line. [N].key.path navigates within that line.
/// Empty path returns EmptyNdjsonPath error with guidance.
pub fn ndjsonExtract(
    buffer: []const u8,
    index: *const NdjsonIndex,
    path_string: []const u8,
) NdjsonError!extract_mod.ExtractResult {
    if (path_string.len == 0) {
        return NdjsonError.EmptyNdjsonPath;
    }

    if (path_string[0] != '[') {
        return NdjsonError.EmptyNdjsonPath;
    }

    const line_info = extractLineIndex(path_string) catch return NdjsonError.EmptyNdjsonPath;

    if (line_info.line_idx >= index.line_count) return NdjsonError.InvalidLineIndex;

    const line_span = index.lineSpan(line_info.line_idx);

    if (line_info.remaining_path.len == 0) {
        // Just [N]: return whole line.
        const value_type = scanner.classifyValue(buffer, line_span.start) catch |err| return err;
        const size = scanner.compactSize(buffer, line_span) catch |err| return err;
        return extract_mod.ExtractResult{
            .path = path_string,
            .value_type = value_type,
            .size = size,
            .value = line_span.slice(buffer),
        };
    }

    // Navigate within the line using the remaining path.
    const line_slice = buffer[line_span.start..line_span.end];
    const parsed_path = path_mod.parsePath(line_info.remaining_path) catch |err| return err;
    const target_span = scanner.navigatePath(
        line_slice,
        0,
        parsed_path.segments[0..parsed_path.length],
    ) catch |err| return err;

    const value_type = scanner.classifyValue(line_slice, target_span.start) catch |err| return err;
    const size = scanner.compactSize(line_slice, target_span) catch |err| return err;

    return extract_mod.ExtractResult{
        .path = path_string,
        .value_type = value_type,
        .size = size,
        .value = target_span.slice(line_slice),
    };
}

/// NDJSON search: searches across all lines for key/value matches.
///
/// For each line, calls searchBuffer on the precisely-trimmed line slice.
/// Returned paths are prefixed with [line_number]. Accumulates matches
/// and respects max_results for early termination.
pub fn ndjsonSearch(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    index: *const NdjsonIndex,
    key_pattern: ?[]const u8,
    value_pattern: ?[]const u8,
    max_results: u32,
) NdjsonError!search_mod.SearchResult {
    std.debug.assert(max_results > 0);

    var all_matches = std.ArrayList(search_mod.SearchMatchResult){};
    errdefer all_matches.deinit(allocator);
    var total_found: u32 = 0;

    for (0..index.line_count) |line_idx| {
        if (all_matches.items.len >= max_results) break;

        const span = index.lineSpan(@intCast(line_idx));
        const line_slice = buffer[span.start..span.end];

        if (line_slice.len == 0) continue;

        const remaining = max_results - @as(u32, @intCast(all_matches.items.len));

        // Use a per-line arena to avoid unbounded memory growth from
        // searchBuffer's internal work stacks across many lines.
        var line_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer line_arena.deinit();

        const line_result = search_mod.searchBuffer(
            line_arena.allocator(),
            line_slice,
            key_pattern,
            value_pattern,
            remaining,
        ) catch continue; // Skip lines that fail to parse.

        total_found += line_result.total_found;

        // Copy matches to the main allocator with [N] path prefix.
        for (line_result.matches) |match_entry| {
            if (all_matches.items.len >= max_results) break;

            const prefixed_path = try buildLinePrefixedPath(allocator, @intCast(line_idx), match_entry.path);
            const preview_copy = try allocator.dupe(u8, match_entry.preview);

            try all_matches.append(allocator, search_mod.SearchMatchResult{
                .path = prefixed_path,
                .value_type = match_entry.value_type,
                .preview = preview_copy,
            });
        }
    }

    return search_mod.SearchResult{
        .matches = try all_matches.toOwnedSlice(allocator),
        .total_found = total_found,
    };
}

/// Builds a path prefixed with [line_number].
fn buildLinePrefixedPath(
    allocator: std.mem.Allocator,
    line_idx: u32,
    original_path: []const u8,
) ![]const u8 {
    var path_buffer = std.ArrayList(u8){};
    errdefer path_buffer.deinit(allocator);

    try path_buffer.append(allocator, '[');
    try std.fmt.format(path_buffer.writer(allocator), "{d}", .{line_idx});
    try path_buffer.append(allocator, ']');

    if (original_path.len > 0) {
        // If original path starts with '[', don't add a dot.
        if (original_path[0] != '[') {
            try path_buffer.append(allocator, '.');
        }
        try path_buffer.appendSlice(allocator, original_path);
    }

    return path_buffer.toOwnedSlice(allocator);
}
