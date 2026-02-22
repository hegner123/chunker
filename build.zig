/// Build configuration for the chunker executable, tests, and release variants.
///
/// Defines:
/// - "chunker" executable from src/main.zig
/// - chunker_lib_module from src/lib.zig (shared with tests as the "chunker" import)
/// - Unit tests from test/unit/all_tests.zig
/// - Integration tests from test/integration/all_tests.zig
/// - Release build steps for ReleaseSafe, ReleaseFast, and ReleaseSmall
///
/// Steps: "run" (build+execute), "test" (all), "test-unit", "test-integration",
/// "release-safe", "release-fast", "release-small".
const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target and optimization options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create a library module for the source code that can be shared with tests
    const chunker_lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main executable module
    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "chunker",
        .root_module = main_module,
    });

    // Install the executable
    b.installArtifact(exe);

    // Create run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Pass arguments to the run command
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Create run step
    const run_step = b.step("run", "Run the chunker MCP server");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_test_module = b.createModule(.{
        .root_source_file = b.path("test/unit/all_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_module.addImport("chunker", chunker_lib_module);

    const unit_tests = b.addTest(.{
        .root_module = unit_test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Integration tests
    const integration_test_module = b.createModule(.{
        .root_source_file = b.path("test/integration/all_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_test_module.addImport("chunker", chunker_lib_module);

    const integration_tests = b.addTest(.{
        .root_module = integration_test_module,
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);

    // Test step that runs all tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Unit tests only
    const unit_test_step = b.step("test-unit", "Run unit tests only");
    unit_test_step.dependOn(&run_unit_tests.step);

    // Integration tests only
    const integration_test_step = b.step("test-integration", "Run integration tests only");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Release builds with specific optimization levels
    const release_safe_exe = b.addExecutable(.{
        .name = "chunker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });

    const release_fast_exe = b.addExecutable(.{
        .name = "chunker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });

    const release_small_exe = b.addExecutable(.{
        .name = "chunker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });

    // Release build steps
    const install_safe = b.addInstallArtifact(release_safe_exe, .{});
    const install_fast = b.addInstallArtifact(release_fast_exe, .{});
    const install_small = b.addInstallArtifact(release_small_exe, .{});

    const release_safe_step = b.step("release-safe", "Build with ReleaseSafe optimization");
    release_safe_step.dependOn(&install_safe.step);

    const release_fast_step = b.step("release-fast", "Build with ReleaseFast optimization");
    release_fast_step.dependOn(&install_fast.step);

    const release_small_step = b.step("release-small", "Build with ReleaseSmall optimization");
    release_small_step.dependOn(&install_small.step);
}
