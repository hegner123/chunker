//! chunker_extract implementation.
//!
//! Navigates a dot-notation path and returns the raw value at that location.
//! Empty path extracts the root value. Returns the value's type and compact
//! byte size alongside the raw JSON.
const std = @import("std");
const types = @import("types.zig");
const scanner = @import("scanner.zig");
const path_mod = @import("path.zig");

const Span = types.Span;
const ValueType = types.ValueType;
const ScanError = types.ScanError;

/// Result of an extract operation.
pub const ExtractResult = struct {
    path: []const u8,
    value_type: ValueType,
    size: u32,
    value: []const u8,
};

/// Extract error set.
pub const ExtractError = ScanError || types.PathError;

/// Extracts the value at a given path from a JSON buffer.
///
/// The returned value is a raw slice of the original buffer (zero-copy).
/// The size field is the compactSize of the value.
pub fn extract(
    buffer: []const u8,
    path_string: []const u8,
) ExtractError!ExtractResult {
    std.debug.assert(buffer.len > 0);

    const root_span = scanner.scanValue(buffer) catch |err| return err;

    const target_span: Span = if (path_string.len == 0)
        root_span
    else blk: {
        const parsed_path = path_mod.parsePath(path_string) catch |err| return err;
        break :blk scanner.navigatePath(
            buffer,
            root_span.start,
            parsed_path.segments[0..parsed_path.length],
        ) catch |err| return err;
    };

    const value_type = scanner.classifyValue(buffer, target_span.start) catch |err| return err;
    const size = scanner.compactSize(buffer, target_span) catch |err| return err;

    std.debug.assert(target_span.end > target_span.start);
    return ExtractResult{
        .path = path_string,
        .value_type = value_type,
        .size = size,
        .value = target_span.slice(buffer),
    };
}
