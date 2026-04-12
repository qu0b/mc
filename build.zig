const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "mc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run mc");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);

    // Phase 1 out-of-tree tests for diagnostic / json_strict. The modules
    // under test are added as imports so the test root can @import them
    // by name.
    const diagnostic_mod = b.createModule(.{
        .root_source_file = b.path("src/io/diagnostic.zig"),
        .target = target,
        .optimize = optimize,
    });
    const json_strict_mod = b.createModule(.{
        .root_source_file = b.path("src/io/json_strict.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diagnostic", .module = diagnostic_mod },
        },
    });

    const diagnostic_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/io/diagnostic_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
            },
        }),
    });
    const run_diagnostic_tests = b.addRunArtifact(diagnostic_tests);
    test_step.dependOn(&run_diagnostic_tests.step);

    const json_strict_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/io/json_strict_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "json_strict", .module = json_strict_mod },
            },
        }),
    });
    const run_json_strict_tests = b.addRunArtifact(json_strict_tests);
    test_step.dependOn(&run_json_strict_tests.step);
}
