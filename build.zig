const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- core modules (shared) ----
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
    const semver_mod = b.createModule(.{
        .root_source_file = b.path("src/io/semver.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_imports = &[_]std.Build.Module.Import{
        .{ .name = "diagnostic", .module = diagnostic_mod },
        .{ .name = "json_strict", .module = json_strict_mod },
        .{ .name = "semver", .module = semver_mod },
    };

    // ---- main executable ----
    const exe = b.addExecutable(.{
        .name = "mc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = core_imports,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run mc");
    run_step.dependOn(&run_cmd.step);

    // Library module (re-used by external test files under tests/).
    const mc_mod = b.addModule("mc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = core_imports,
    });

    // Unit tests (inline tests inside src/).
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = core_imports,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // External integration tests under tests/.
    const semver_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/io/semver_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "mc", .module = mc_mod }},
        }),
    });
    const run_semver_tests = b.addRunArtifact(semver_tests);

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

    // ---- Phase 3 schema modules ----
    const agent_schema_mod = b.createModule(.{
        .root_source_file = b.path("src/schema/agent.zig"),
        .target = target,
        .optimize = optimize,
        .imports = core_imports,
    });
    const plugin_strict_mod = b.createModule(.{
        .root_source_file = b.path("src/schema/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .imports = core_imports,
    });
    const toolset_mod = b.createModule(.{
        .root_source_file = b.path("src/schema/toolset.zig"),
        .target = target,
        .optimize = optimize,
        .imports = core_imports,
    });
    const library_mod = b.createModule(.{
        .root_source_file = b.path("src/schema/library.zig"),
        .target = target,
        .optimize = optimize,
        .imports = core_imports,
    });

    const agent_schema_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/schema/agent_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "agent", .module = agent_schema_mod },
            },
        }),
    });
    const run_agent_schema_tests = b.addRunArtifact(agent_schema_tests);

    const plugin_strict_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/schema/plugin_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "plugin", .module = plugin_strict_mod },
            },
        }),
    });
    const run_plugin_strict_tests = b.addRunArtifact(plugin_strict_tests);

    const toolset_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/schema/toolset_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "toolset", .module = toolset_mod },
            },
        }),
    });
    const run_toolset_tests = b.addRunArtifact(toolset_tests);

    const library_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/schema/library_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "library", .module = library_mod },
            },
        }),
    });
    const run_library_tests = b.addRunArtifact(library_tests);

    // ---- Phase 11: agent CLI scaffolder ----
    const args_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/args.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/agent.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "args", .module = args_mod },
        },
    });
    const agent_cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli/agent_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent_cli_mod },
            },
        }),
    });
    const run_agent_cli_tests = b.addRunArtifact(agent_cli_tests);

    // ---- Phase 5: core/toolset_resolver ----
    const toolset_resolver_mod = b.createModule(.{
        .root_source_file = b.path("src/core/toolset_resolver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diagnostic", .module = diagnostic_mod },
            .{ .name = "toolset", .module = toolset_mod },
        },
    });

    const toolset_resolver_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core/toolset_resolver_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "toolset", .module = toolset_mod },
                .{ .name = "toolset_resolver", .module = toolset_resolver_mod },
            },
        }),
    });
    const run_toolset_resolver_tests = b.addRunArtifact(toolset_resolver_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_semver_tests.step);
    test_step.dependOn(&run_diagnostic_tests.step);
    test_step.dependOn(&run_json_strict_tests.step);
    test_step.dependOn(&run_agent_schema_tests.step);
    test_step.dependOn(&run_plugin_strict_tests.step);
    test_step.dependOn(&run_toolset_tests.step);
    test_step.dependOn(&run_library_tests.step);
    test_step.dependOn(&run_agent_cli_tests.step);
    test_step.dependOn(&run_toolset_resolver_tests.step);
}
