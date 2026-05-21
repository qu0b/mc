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
    // The Zig 0.16 I/O compatibility layer. Shared by the exe root and several
    // named modules, so it must itself be a named leaf module (a file may only
    // belong to one module). Needs libc for getenv.
    const iocompat_mod = b.createModule(.{
        .root_source_file = b.path("src/io/compat.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // mmap + json are likewise shared between the exe root and the `plugin`
    // named module, so they are named leaf modules too.
    const mmap_mod = b.createModule(.{
        .root_source_file = b.path("src/io/mmap.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "iocompat", .module = iocompat_mod }},
    });
    const io_json_mod = b.createModule(.{
        .root_source_file = b.path("src/io/json.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "mmap", .module = mmap_mod }},
    });
    // Shared test-fixture helpers (Zig 0.16 std.Io.Dir wrappers).
    const testutil_mod = b.createModule(.{
        .root_source_file = b.path("tests/testutil.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "iocompat", .module = iocompat_mod }},
    });
    const core_imports = &[_]std.Build.Module.Import{
        .{ .name = "diagnostic", .module = diagnostic_mod },
        .{ .name = "json_strict", .module = json_strict_mod },
        .{ .name = "semver", .module = semver_mod },
    };

    // ---- main executable ----
    // The CLI/core/schema files reach each other through *named* module
    // imports (e.g. `@import("agent")`). The exe's root module must therefore
    // expose every such module; the full set is wired up after all modules are
    // declared, via `exe_root.addImport(...)` near the end of this function.
    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = core_imports,
    });
    const exe = b.addExecutable(.{
        .name = "mc",
        .root_module = exe_root,
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

    // Unit tests (inline tests inside src/). Shares the library module's full
    // import set, wired up below once every named module is declared.
    const lib_test_root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = core_imports,
    });
    const unit_tests = b.addTest(.{ .root_module = lib_test_root });
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
        .imports = &[_]std.Build.Module.Import{
            .{ .name = "diagnostic", .module = diagnostic_mod },
            .{ .name = "json_strict", .module = json_strict_mod },
            .{ .name = "semver", .module = semver_mod },
            .{ .name = "iocompat", .module = iocompat_mod },
            .{ .name = "mmap", .module = mmap_mod },
            .{ .name = "json", .module = io_json_mod },
        },
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
            .{ .name = "iocompat", .module = iocompat_mod },
            .{ .name = "agent_schema", .module = agent_schema_mod },
            .{ .name = "diagnostic", .module = diagnostic_mod },
            // "emit" added below, after emit_mod is declared.
        },
    });
    const agent_cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli/agent_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent_cli_mod },
                .{ .name = "testutil", .module = testutil_mod },
            },
        }),
    });
    const run_agent_cli_tests = b.addRunArtifact(agent_cli_tests);

    const agent_show_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli/agent_show_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent_cli_mod },
                .{ .name = "testutil", .module = testutil_mod },
            },
        }),
    });
    const run_agent_show_tests = b.addRunArtifact(agent_show_tests);

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

    // ---- Phase 6: core/agent_resolver ----
    const agent_resolver_mod = b.createModule(.{
        .root_source_file = b.path("src/core/agent_resolver.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diagnostic", .module = diagnostic_mod },
            .{ .name = "agent", .module = agent_schema_mod },
            .{ .name = "toolset", .module = toolset_mod },
            .{ .name = "iocompat", .module = iocompat_mod },
        },
    });
    const agent_resolver_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core/agent_resolver_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "agent", .module = agent_schema_mod },
                .{ .name = "toolset", .module = toolset_mod },
                .{ .name = "agent_resolver", .module = agent_resolver_mod },
                .{ .name = "testutil", .module = testutil_mod },
            },
        }),
    });
    const run_agent_resolver_tests = b.addRunArtifact(agent_resolver_tests);

    // ---- Phase 4: core/compat ----
    const core_compat_mod = b.createModule(.{
        .root_source_file = b.path("src/core/compat.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diagnostic", .module = diagnostic_mod },
            .{ .name = "semver", .module = semver_mod },
            .{ .name = "plugin", .module = plugin_strict_mod },
            .{ .name = "iocompat", .module = iocompat_mod },
        },
    });
    const compat_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core/compat_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "semver", .module = semver_mod },
                .{ .name = "plugin", .module = plugin_strict_mod },
                .{ .name = "compat", .module = core_compat_mod },
            },
        }),
    });
    const run_compat_tests = b.addRunArtifact(compat_tests);

    const add_compat_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli/add_compat_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "semver", .module = semver_mod },
                .{ .name = "plugin", .module = plugin_strict_mod },
                .{ .name = "compat", .module = core_compat_mod },
                .{ .name = "iocompat", .module = iocompat_mod },
            },
        }),
    });
    const run_add_compat_tests = b.addRunArtifact(add_compat_tests);

    // ---- Phase 7: core/materialize ----
    const materialize_mod = b.createModule(.{
        .root_source_file = b.path("src/core/materialize.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diagnostic", .module = diagnostic_mod },
            .{ .name = "agent", .module = agent_schema_mod },
            .{ .name = "iocompat", .module = iocompat_mod },
        },
    });
    const materialize_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core/materialize_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "agent", .module = agent_schema_mod },
                .{ .name = "materialize", .module = materialize_mod },
                .{ .name = "testutil", .module = testutil_mod },
                .{ .name = "iocompat", .module = iocompat_mod },
            },
        }),
    });
    const run_materialize_tests = b.addRunArtifact(materialize_tests);

    // ---- Phase 10: cli/validate ----
    const validate_cli_imports = [_]std.Build.Module.Import{
        .{ .name = "diagnostic", .module = diagnostic_mod },
        .{ .name = "plugin", .module = plugin_strict_mod },
        .{ .name = "agent", .module = agent_schema_mod },
        .{ .name = "toolset", .module = toolset_mod },
        .{ .name = "library", .module = library_mod },
        .{ .name = "agent_resolver", .module = agent_resolver_mod },
        .{ .name = "toolset_resolver", .module = toolset_resolver_mod },
        .{ .name = "compat", .module = core_compat_mod },
        .{ .name = "iocompat", .module = iocompat_mod },
    };
    const validate_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/validate.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &validate_cli_imports,
    });

    const validate_cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli/validate_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "validate", .module = validate_cli_mod },
                .{ .name = "testutil", .module = testutil_mod },
            },
        }),
    });
    const run_validate_cli_tests = b.addRunArtifact(validate_cli_tests);

    // ---- Phase 8: cli/run ----
    const run_cmd_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/run.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "diagnostic", .module = diagnostic_mod },
            .{ .name = "agent", .module = agent_schema_mod },
            .{ .name = "toolset", .module = toolset_mod },
            .{ .name = "agent_resolver", .module = agent_resolver_mod },
            .{ .name = "toolset_resolver", .module = toolset_resolver_mod },
            .{ .name = "materialize", .module = materialize_mod },
            .{ .name = "iocompat", .module = iocompat_mod },
        },
    });
    const run_cmd_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli/run_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "run", .module = run_cmd_mod },
                .{ .name = "testutil", .module = testutil_mod },
            },
        }),
    });
    const run_run_cmd_tests = b.addRunArtifact(run_cmd_tests);

    // ---- Phase 12: agent-config superset emitters ----
    const emit_mod = b.createModule(.{
        .root_source_file = b.path("src/core/emit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "agent", .module = agent_schema_mod },
        },
    });
    const emit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/core/emit_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "diagnostic", .module = diagnostic_mod },
                .{ .name = "agent", .module = agent_schema_mod },
                .{ .name = "emit", .module = emit_mod },
            },
        }),
    });
    const run_emit_tests = b.addRunArtifact(emit_tests);

    // `mc agent emit` (in the agent CLI module) renders via the emitters.
    agent_cli_mod.addImport("emit", emit_mod);

    // Wire every named module the exe's CLI/core/schema files import into the
    // exe root module (they share one import table since they are pulled in via
    // relative imports).
    exe_root.addImport("agent", agent_schema_mod);
    // Alias used by cli/agent.zig (whose test build reserves "agent" for the
    // CLI module itself).
    exe_root.addImport("agent_schema", agent_schema_mod);
    exe_root.addImport("toolset", toolset_mod);
    exe_root.addImport("library", library_mod);
    exe_root.addImport("plugin", plugin_strict_mod);
    exe_root.addImport("agent_resolver", agent_resolver_mod);
    exe_root.addImport("toolset_resolver", toolset_resolver_mod);
    exe_root.addImport("materialize", materialize_mod);
    exe_root.addImport("compat", core_compat_mod);
    exe_root.addImport("emit", emit_mod);
    exe_root.addImport("iocompat", iocompat_mod);
    exe_root.addImport("mmap", mmap_mod);
    exe_root.addImport("json", io_json_mod);

    // The library module (`@import("mc")`) and its inline-test runner re-export
    // the same named modules so the whole public surface in `src/root.zig`
    // actually compiles for consumers.
    const lib_named = [_]std.Build.Module.Import{
        .{ .name = "iocompat", .module = iocompat_mod },
        .{ .name = "mmap", .module = mmap_mod },
        .{ .name = "json", .module = io_json_mod },
        .{ .name = "agent", .module = agent_schema_mod },
        .{ .name = "toolset", .module = toolset_mod },
        .{ .name = "library", .module = library_mod },
        .{ .name = "plugin", .module = plugin_strict_mod },
        .{ .name = "agent_resolver", .module = agent_resolver_mod },
        .{ .name = "toolset_resolver", .module = toolset_resolver_mod },
        .{ .name = "materialize", .module = materialize_mod },
        .{ .name = "compat", .module = core_compat_mod },
        .{ .name = "emit", .module = emit_mod },
    };
    for (lib_named) |imp| {
        mc_mod.addImport(imp.name, imp.module);
        lib_test_root.addImport(imp.name, imp.module);
    }

    // ---- runnable library-consumer example ----
    const example_exe = b.addExecutable(.{
        .name = "emit_agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/emit_agent.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "mc", .module = mc_mod }},
        }),
    });
    const run_example = b.addRunArtifact(example_exe);
    const example_step = b.step("example", "Build & run the library-consumer example");
    example_step.dependOn(&run_example.step);

    // Pure config-layer tests (no filesystem); buildable independently of the
    // CLI exe so the agent-config superset can be validated in isolation.
    const test_config_step = b.step("test-config", "Run agent-config superset + emitter tests");
    test_config_step.dependOn(&run_agent_schema_tests.step);
    test_config_step.dependOn(&run_emit_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_emit_tests.step);
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_semver_tests.step);
    test_step.dependOn(&run_diagnostic_tests.step);
    test_step.dependOn(&run_json_strict_tests.step);
    test_step.dependOn(&run_agent_schema_tests.step);
    test_step.dependOn(&run_plugin_strict_tests.step);
    test_step.dependOn(&run_toolset_tests.step);
    test_step.dependOn(&run_library_tests.step);
    test_step.dependOn(&run_agent_cli_tests.step);
    test_step.dependOn(&run_agent_show_tests.step);
    test_step.dependOn(&run_toolset_resolver_tests.step);
    test_step.dependOn(&run_agent_resolver_tests.step);
    test_step.dependOn(&run_compat_tests.step);
    test_step.dependOn(&run_add_compat_tests.step);
    test_step.dependOn(&run_materialize_tests.step);
    test_step.dependOn(&run_validate_cli_tests.step);
    test_step.dependOn(&run_run_cmd_tests.step);
}
