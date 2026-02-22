//! Test harness that imports all unit test modules.
//! Each module's tests are discovered and run by the Zig test runner.
comptime {
    _ = @import("scanner_test.zig");
    _ = @import("scanner_strings_test.zig");
    _ = @import("path_test.zig");
    _ = @import("mmap_test.zig");
    _ = @import("inspect_test.zig");
    _ = @import("read_test.zig");
    _ = @import("extract_test.zig");
    _ = @import("search_test.zig");
    _ = @import("ndjson_test.zig");
}
