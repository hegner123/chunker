//! Public re-exports for test access.
//!
//! Tests import this module as "chunker" to access all internal modules
//! without reaching into the src/ directory structure directly.
pub const types = @import("types.zig");
pub const config = @import("config.zig");
pub const scanner = @import("scanner.zig");
pub const scanner_strings = @import("scanner_strings.zig");
pub const path = @import("path.zig");
pub const output = @import("output.zig");
pub const mmap = @import("mmap.zig");
pub const inspect = @import("inspect.zig");
pub const read = @import("read.zig");
pub const extract = @import("extract.zig");
pub const search = @import("search.zig");
pub const mcp = @import("mcp.zig");
pub const ndjson = @import("ndjson.zig");
