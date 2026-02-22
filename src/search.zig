//! chunker_search implementation.
//!
//! Iterative stack-based traversal searching for key and/or value matches.
//! Uses a heap-allocated stack instead of recursion (Tiger Style: no recursion).
//! Builds dot-notation paths as traversal descends. Match results collected
//! in an arena-allocated list.
const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
const scanner_strings = @import("scanner_strings.zig");

const Pos = types.Pos;
const Span = types.Span;
const ValueType = types.ValueType;
const ScanError = types.ScanError;

/// A single search match.
pub const SearchMatchResult = struct {
    path: []const u8,
    value_type: ValueType,
    preview: []const u8,
};

/// Result of a search operation.
pub const SearchResult = struct {
    matches: []SearchMatchResult,
    total_found: u32,
};

/// Search error set.
pub const SearchError = ScanError || error{
    OutOfMemory,
};

/// Work item for the iterative traversal stack.
const WorkItem = struct {
    pos: Pos,
    path: []const u8,
};

/// Mutable search state threaded through all helpers.
const SearchState = struct {
    allocator: std.mem.Allocator,
    buffer: []const u8,
    key_pattern: ?[]const u8,
    value_pattern: ?[]const u8,
    max_results: u32,
    matches: std.ArrayList(SearchMatchResult),
    total_found: u32,
    work_stack: std.ArrayList(WorkItem),
};

/// Searches a JSON buffer for key and/or value matches.
///
/// When both key_pattern and value_pattern are provided, matches are additive
/// (key match OR value match). Deduplication: if the same path matches on
/// both key and value, a single match entry is emitted.
pub fn searchBuffer(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    key_pattern: ?[]const u8,
    value_pattern: ?[]const u8,
    max_results: u32,
) SearchError!SearchResult {
    std.debug.assert(buffer.len > 0);
    std.debug.assert(max_results > 0);

    const root_span = scanner.scanValue(buffer) catch |err| return err;

    var state = SearchState{
        .allocator = allocator,
        .buffer = buffer,
        .key_pattern = key_pattern,
        .value_pattern = value_pattern,
        .max_results = max_results,
        .matches = std.ArrayList(SearchMatchResult){},
        .total_found = 0,
        .work_stack = std.ArrayList(WorkItem){},
    };
    errdefer state.matches.deinit(allocator);
    defer state.work_stack.deinit(allocator);

    // Seed the stack with the root value.
    try state.work_stack.append(allocator, WorkItem{
        .pos = root_span.start,
        .path = try allocator.dupe(u8, ""),
    });

    // Iterative traversal: process work items until stack is empty.
    while (state.work_stack.items.len > 0) {
        const item = state.work_stack.pop().?;
        try processWorkItem(&state, item);
    }

    return SearchResult{
        .matches = try state.matches.toOwnedSlice(allocator),
        .total_found = state.total_found,
    };
}

/// Processes a single work item: checks value match, then pushes children if container.
fn processWorkItem(state: *SearchState, item: WorkItem) SearchError!void {
    const pos = scanner.skipWhitespace(state.buffer, item.pos);
    if (pos >= state.buffer.len) return;

    const value_type = scanner.classifyValue(state.buffer, pos) catch return;
    const value_end = scanner.skipValue(state.buffer, pos) catch return;
    const value_span = Span{ .start = pos, .end = value_end };

    // Check value match.
    if (state.value_pattern) |pattern| {
        if (matchesValue(state.buffer, value_span, value_type, pattern)) {
            try recordMatch(state, item.path, value_type, value_span);
        }
    }

    // Push children of containers onto the work stack.
    switch (value_type) {
        .array => try pushArrayChildren(state, pos, item.path),
        .object => try pushObjectChildren(state, pos, item.path),
        else => {},
    }
}

/// Records a match, incrementing total_found and appending if under max_results.
fn recordMatch(
    state: *SearchState,
    path: []const u8,
    value_type: ValueType,
    value_span: Span,
) !void {
    state.total_found += 1;
    if (state.matches.items.len >= state.max_results) return;
    if (pathAlreadyMatched(state.matches.items, path)) return;

    const preview = try buildPreview(state.allocator, state.buffer, value_span);
    try state.matches.append(state.allocator, SearchMatchResult{
        .path = try state.allocator.dupe(u8, path),
        .value_type = value_type,
        .preview = preview,
    });
}

/// Pushes all elements of a JSON array onto the work stack with indexed paths.
fn pushArrayChildren(state: *SearchState, array_start: Pos, parent_path: []const u8) !void {
    var cursor: Pos = array_start + 1;
    var element_index: u32 = 0;

    while (true) {
        cursor = scanner.skipWhitespace(state.buffer, cursor);
        if (cursor >= state.buffer.len or state.buffer[cursor] == ']') break;
        if (state.buffer[cursor] == ',') {
            cursor += 1;
            cursor = scanner.skipWhitespace(state.buffer, cursor);
        }
        if (cursor >= state.buffer.len or state.buffer[cursor] == ']') break;

        const child_path = try buildArrayPath(state.allocator, parent_path, element_index);
        const element_end = scanner.skipValue(state.buffer, cursor) catch break;

        try state.work_stack.append(state.allocator, WorkItem{
            .pos = cursor,
            .path = child_path,
        });

        cursor = element_end;
        element_index += 1;
    }
}

/// Pushes all values of a JSON object onto the work stack with keyed paths.
/// Also checks key matches and records them immediately.
fn pushObjectChildren(state: *SearchState, object_start: Pos, parent_path: []const u8) !void {
    var cursor: Pos = object_start + 1;

    while (true) {
        cursor = scanner.skipWhitespace(state.buffer, cursor);
        if (cursor >= state.buffer.len or state.buffer[cursor] == '}') break;
        if (state.buffer[cursor] == ',') {
            cursor += 1;
            cursor = scanner.skipWhitespace(state.buffer, cursor);
        }
        if (cursor >= state.buffer.len or state.buffer[cursor] == '}') break;
        if (state.buffer[cursor] != '"') break;

        const key_start = cursor;
        const key_end = scanner_strings.skipString(state.buffer, cursor) catch break;
        const key_span = Span{ .start = key_start, .end = key_end };
        const key_text = state.buffer[key_start + 1 .. key_end - 1];

        // Skip colon.
        cursor = scanner.skipWhitespace(state.buffer, key_end);
        if (cursor < state.buffer.len and state.buffer[cursor] == ':') cursor += 1;
        cursor = scanner.skipWhitespace(state.buffer, cursor);

        const value_start = cursor;
        const child_value_end = scanner.skipValue(state.buffer, cursor) catch break;
        const child_path = try buildObjectPath(state.allocator, parent_path, key_text);

        // Check key match.
        if (state.key_pattern) |pattern| {
            if (keyMatches(state.buffer, key_span, pattern)) {
                const child_type = scanner.classifyValue(state.buffer, value_start) catch .null_type;
                const child_span = Span{ .start = value_start, .end = child_value_end };
                try recordMatch(state, child_path, child_type, child_span);
            }
        }

        try state.work_stack.append(state.allocator, WorkItem{
            .pos = value_start,
            .path = child_path,
        });

        cursor = child_value_end;
    }
}

/// Checks if a value matches the search pattern.
/// For strings: substring match against decoded content (without quotes).
/// For non-strings: exact match against raw JSON bytes.
fn matchesValue(
    buffer: []const u8,
    value_span: Span,
    value_type: ValueType,
    pattern: []const u8,
) bool {
    if (value_type == .string) {
        const content = buffer[value_span.start + 1 .. value_span.end - 1];
        return std.mem.indexOf(u8, content, pattern) != null;
    }
    // Non-string: exact match against raw JSON token.
    const raw = value_span.slice(buffer);
    return std.mem.eql(u8, raw, pattern);
}

/// Checks if an object key matches the search pattern (substring).
fn keyMatches(buffer: []const u8, key_span: Span, pattern: []const u8) bool {
    if (key_span.len() < 2) return false;
    const content = buffer[key_span.start + 1 .. key_span.end - 1];
    return std.mem.indexOf(u8, content, pattern) != null;
}

/// Checks if a path is already in the match list (deduplication).
fn pathAlreadyMatched(matches: []const SearchMatchResult, check_path: []const u8) bool {
    for (matches) |match_entry| {
        if (std.mem.eql(u8, match_entry.path, check_path)) return true;
    }
    return false;
}

/// Builds a preview string: first N bytes of the value's raw JSON.
fn buildPreview(
    allocator: std.mem.Allocator,
    buffer: []const u8,
    value_span: Span,
) ![]const u8 {
    const raw = value_span.slice(buffer);
    if (raw.len <= config.preview_max_bytes) {
        return try allocator.dupe(u8, raw);
    }
    var preview = try allocator.alloc(u8, config.preview_max_bytes + 3);
    @memcpy(preview[0..config.preview_max_bytes], raw[0..config.preview_max_bytes]);
    preview[config.preview_max_bytes] = '.';
    preview[config.preview_max_bytes + 1] = '.';
    preview[config.preview_max_bytes + 2] = '.';
    return preview;
}

/// Builds a path string for an array element: "prefix[N]"
fn buildArrayPath(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    index: u32,
) ![]const u8 {
    var path_buffer = std.ArrayList(u8){};
    errdefer path_buffer.deinit(allocator);
    try path_buffer.appendSlice(allocator, prefix);
    try path_buffer.append(allocator, '[');
    try std.fmt.format(path_buffer.writer(allocator), "{d}", .{index});
    try path_buffer.append(allocator, ']');
    return path_buffer.toOwnedSlice(allocator);
}

/// Builds a path string for an object key: "prefix.key" or "key" if prefix is empty.
fn buildObjectPath(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    key: []const u8,
) ![]const u8 {
    var path_buffer = std.ArrayList(u8){};
    errdefer path_buffer.deinit(allocator);
    if (prefix.len > 0) {
        try path_buffer.appendSlice(allocator, prefix);
        try path_buffer.append(allocator, '.');
    }
    try path_buffer.appendSlice(allocator, key);
    return path_buffer.toOwnedSlice(allocator);
}
