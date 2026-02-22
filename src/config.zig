//! Compile-time constants for the chunker MCP tool.
//!
//! All limits and defaults are defined here. Comptime assertions enforce
//! invariants at build time: max_file_size fits in u32, and the target
//! architecture is 64-bit.
const std = @import("std");

/// Maximum file size accepted by mmap: 1 GiB (1,073,741,824 bytes).
/// Files exactly this size are accepted; files strictly larger are rejected.
pub const max_file_size: u64 = 1024 * 1024 * 1024;

/// Default chunk size in bytes of compact JSON content.
pub const default_chunk_size: u32 = 10_000;

/// Minimum allowed chunk_size parameter. Values below this are rejected.
pub const min_chunk_size: u32 = 1;

/// Default maximum search results returned.
pub const default_max_results: u32 = 10;

/// Maximum JSON nesting depth tracked by the scanner bracket stack.
pub const max_nesting_depth: u16 = 256;

/// Maximum number of dot-notation path segments (stack-allocated).
pub const max_path_segments: u16 = 64;

/// Maximum number of object keys before the pair buffer allocation is refused.
pub const max_object_keys: u32 = 1_000_000;

/// Maximum number of NDJSON lines before the line index allocation is refused.
pub const max_ndjson_lines: u32 = 1_000_000;

/// Maximum bytes shown in a search match preview before truncation.
pub const preview_max_bytes: u32 = 100;

/// UTF-8 BOM prefix bytes (EF BB BF).
pub const utf8_bom = [3]u8{ 0xEF, 0xBB, 0xBF };

// -- Comptime invariants --

comptime {
    // u32 positions must be sufficient for the maximum file size.
    std.debug.assert(max_file_size < std.math.maxInt(u32));

    // This tool targets 64-bit architectures only.
    std.debug.assert(@sizeOf(usize) >= 8);
}
