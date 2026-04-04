const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library
    const lib = b.addLibrary(.{
        .name = "apex",
        .root_module = root_module,
    });
    b.installArtifact(lib);

    // Shared library (for C ABI) - use addLibrary with .dynamic linkage
    const shared_module = b.createModule(.{
        .root_source_file = b.path("src/cabi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_lib = b.addLibrary(.{
        .name = "apex-shared",
        .root_module = shared_module,
        .linkage = .dynamic,
    });
    b.installArtifact(shared_lib);

    // Install header
    b.installFile("include/apex.h", "include/apex.h");

    // Unit tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // C ABI tests
    const cabi_test_module = b.createModule(.{
        .root_source_file = b.path("src/cabi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cabi_tests = b.addTest(.{
        .root_module = cabi_test_module,
    });
    const run_cabi_tests = b.addRunArtifact(cabi_tests);
    test_step.dependOn(&run_cabi_tests.step);

    // Benchmark executable - uses release-optimized apex
    const apex_release_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{
            .{ .name = "apex", .module = apex_release_module },
        },
    });
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Debug build (full checks, stats, logging)
    const debug_step = b.step("debug", "Build debug version with full checks");
    const debug_lib = b.addLibrary(.{
        .name = "apex-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    debug_step.dependOn(&b.addInstallArtifact(debug_lib, .{}).step);

    // Safe build (release + bounds checking)
    const safe_step = b.step("safe", "Build safe version with bounds checking");
    const safe_lib = b.addLibrary(.{
        .name = "apex-safe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    safe_step.dependOn(&b.addInstallArtifact(safe_lib, .{}).step);

    // Fast build (maximum performance)
    const fast_step = b.step("fast", "Build fast version for maximum performance");
    const fast_lib = b.addLibrary(.{
        .name = "apex-fast",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    fast_step.dependOn(&b.addInstallArtifact(fast_lib, .{}).step);
}
