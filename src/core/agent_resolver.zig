const std = @import("std");
const diag = @import("diagnostic");
const agent_schema = @import("agent");
const toolset_schema = @import("toolset");
const compat = @import("iocompat");

/// Context required to cross-validate a parsed agent against the project
/// layout (installed capabilities, toolset registry, on-disk prompt file).
pub const ResolveContext = struct {
    /// Absolute path to the project root (the sandbox).
    project_root: []const u8,
    /// Absolute path to the agent's own directory (e.g. `<root>/agents/foo`).
    /// Used to resolve the relative `prompt` path.
    agent_dir: []const u8,
    /// Names of capabilities currently installed (dir names under
    /// `<root>/.mc/plugins/`).
    installed_capabilities: []const []const u8,
    /// Toolset registry parsed from a `toolsets.json`; may be null if no
    /// registry was found — in that case toolset existence checks are
    /// skipped and a single informational diagnostic is emitted.
    toolsets: ?*const toolset_schema.ToolsetRegistry,
};

/// Run cross-file semantic validation on a parsed Agent.
/// Emits diagnostics; returns true iff no error-severity diagnostics were
/// added by this call (warnings do not affect the return value).
pub fn validate(
    allocator: std.mem.Allocator,
    agent: agent_schema.Agent,
    agent_file: []const u8,
    ctx: ResolveContext,
    diags: *diag.Diagnostics,
) !bool {
    const errs_before = countErrors(diags);

    // Build O(1) lookup set of installed capability names.
    var installed = std.StringHashMap(void).init(allocator);
    defer installed.deinit();
    for (ctx.installed_capabilities) |name| try installed.put(name, {});

    // skills[i]: must be installed.
    for (agent.capabilities.skills, 0..) |name, i| {
        if (!installed.contains(name)) {
            const path = try std.fmt.allocPrint(
                diags.arena.allocator(),
                "capabilities.skills[{d}]",
                .{i},
            );
            try diags.err(agent_file, path, "capability '{s}' not installed", .{name});
        }
    }

    // extensions[i]: must be installed.
    for (agent.capabilities.extensions, 0..) |name, i| {
        if (!installed.contains(name)) {
            const path = try std.fmt.allocPrint(
                diags.arena.allocator(),
                "capabilities.extensions[{d}]",
                .{i},
            );
            try diags.err(agent_file, path, "capability '{s}' not installed", .{name});
        }
    }

    // commands[i]: v1 can't yet resolve these — emit a warning.
    for (agent.capabilities.commands, 0..) |name, i| {
        const path = try std.fmt.allocPrint(
            diags.arena.allocator(),
            "capabilities.commands[{d}]",
            .{i},
        );
        try diags.warn(
            agent_file,
            path,
            "command resolution not yet implemented (TODO): '{s}'",
            .{name},
        );
    }

    // toolset: must exist in the registry (if we have one).
    if (ctx.toolsets) |reg| {
        if (!reg.entries.contains(agent.capabilities.toolset)) {
            const path = try diags.arena.allocator().dupe(u8, "capabilities.toolset");
            try diags.err(
                agent_file,
                path,
                "toolset '{s}' not found in registry",
                .{agent.capabilities.toolset},
            );
        }
    } else {
        const path = try diags.arena.allocator().dupe(u8, "capabilities.toolset");
        try diags.warn(
            agent_file,
            path,
            "no toolsets.json available — toolset '{s}' unverifiable (will fail at runtime)",
            .{agent.capabilities.toolset},
        );
    }

    // prompt: path must resolve to an existing file.
    const prompt_abs = try std.fs.path.join(
        allocator,
        &.{ ctx.agent_dir, agent.prompt },
    );
    defer allocator.free(prompt_abs);
    compat.accessAbsolute(prompt_abs) catch {
        const path = try diags.arena.allocator().dupe(u8, "prompt");
        const msg_path = try diags.arena.allocator().dupe(u8, prompt_abs);
        try diags.err(agent_file, path, "prompt file not found: {s}", .{msg_path});
    };

    return countErrors(diags) == errs_before;
}

fn countErrors(diags: *const diag.Diagnostics) usize {
    var n: usize = 0;
    for (diags.items.items) |it| {
        if (it.severity == .err) n += 1;
    }
    return n;
}

/// Convenience helper: walk the project on disk and run `validate()` for
/// the named agent. Returns false on any error (including load failures),
/// in which case diagnostics describing the failure have been emitted.
pub fn validateAgentInProject(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    agent_name: []const u8,
    diags: *diag.Diagnostics,
) !bool {
    // All transient parse buffers live in this arena; registry entries are
    // only referenced for the lifetime of this function so this is safe.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    // 1. Must be a sandbox.
    const mc_marker = try std.fmt.allocPrint(arena, "{s}/.mc/mc.json", .{project_root});
    compat.accessAbsolute(mc_marker) catch {
        try diags.err(project_root, "", "not an mc sandbox (no .mc/mc.json)", .{});
        return false;
    };

    // 2. Load agent.json.
    const agent_dir = try std.fmt.allocPrint(
        arena,
        "{s}/agents/{s}",
        .{ project_root, agent_name },
    );
    const agent_file_abs = try std.fmt.allocPrint(arena, "{s}/agent.json", .{agent_dir});
    const agent_file_rel = try std.fmt.allocPrint(
        diags.arena.allocator(),
        "agents/{s}/agent.json",
        .{agent_name},
    );

    const src = compat.readFile(arena, agent_file_abs) catch {
        try diags.err(agent_file_rel, "", "agent.json not found or unreadable", .{});
        return false;
    };

    const parsed = try agent_schema.parseAgent(arena, agent_file_rel, src, diags);
    const agent = parsed orelse return false;

    // 3. Locate a toolsets.json via the search order.
    const ts_src_info = try findToolsetsJson(arena, project_root, diags);

    var toolsets: ?toolset_schema.ToolsetRegistry = null;
    defer if (toolsets) |*r| r.deinit();

    var toolsets_ptr: ?*const toolset_schema.ToolsetRegistry = null;
    if (ts_src_info) |info| {
        if (try toolset_schema.parseToolsets(arena, info.rel_file, info.contents, diags)) |r| {
            toolsets = r;
            toolsets_ptr = &toolsets.?;
        }
    }

    // 4. Enumerate installed capabilities.
    const installed = try listInstalledCapabilities(arena, project_root);

    // 5. Validate.
    const ctx = ResolveContext{
        .project_root = project_root,
        .agent_dir = agent_dir,
        .installed_capabilities = installed,
        .toolsets = toolsets_ptr,
    };
    return validate(allocator, agent, agent_file_rel, ctx, diags);
}

// --- helpers ---

const ToolsetsSource = struct {
    /// Short label for diagnostics (owned by `diags.arena`).
    rel_file: []const u8,
    /// File contents owned by `allocator`; caller frees.
    contents: []u8,
};

/// Search order:
/// 1. `<project_root>/toolsets.json`
/// 2. `<project_root>/.mc/toolsets.json`
/// 3. `<project_root>/.mc/plugins/<first-with-toolsets.json>/toolsets.json`
fn findToolsetsJson(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    diags: *diag.Diagnostics,
) !?ToolsetsSource {
    const candidates = [_][]const u8{ "toolsets.json", ".mc/toolsets.json" };
    for (candidates) |rel| {
        const abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, rel });
        defer allocator.free(abs);
        if (compat.readFile(allocator, abs)) |data| {
            return .{
                .rel_file = try diags.arena.allocator().dupe(u8, rel),
                .contents = data,
            };
        } else |_| {}
    }

    // Walk installed plugins for one carrying a toolsets.json.
    const plugins_dir_path = try std.fmt.allocPrint(
        allocator,
        "{s}/.mc/plugins",
        .{project_root},
    );
    defer allocator.free(plugins_dir_path);
    var plugins_dir = compat.openDirAbsolute(plugins_dir_path) catch return null;
    defer plugins_dir.close(compat.getIo());

    var it = compat.iterateDir(plugins_dir);
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const abs = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/toolsets.json",
            .{ plugins_dir_path, entry.name },
        );
        defer allocator.free(abs);
        if (compat.readFile(allocator, abs)) |data| {
            const label = try std.fmt.allocPrint(
                diags.arena.allocator(),
                ".mc/plugins/{s}/toolsets.json",
                .{entry.name},
            );
            return .{
                .rel_file = label,
                .contents = data,
            };
        } else |_| {}
    }
    return null;
}

fn listInstalledCapabilities(
    allocator: std.mem.Allocator,
    project_root: []const u8,
) ![][]const u8 {
    const plugins_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/.mc/plugins",
        .{project_root},
    );
    defer allocator.free(plugins_dir);

    var dir = compat.openDirAbsolute(plugins_dir) catch {
        return allocator.alloc([]const u8, 0);
    };
    defer dir.close(compat.getIo());

    var names: std.ArrayList([]const u8) = .empty;
    var it = compat.iterateDir(dir);
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(allocator);
}
