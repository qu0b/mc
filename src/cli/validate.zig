// Phase 10: `mc validate` — one-shot project-wide config validation.
//
// Walks an mc sandbox from its root and runs every validator we have:
//   1. Every .mc/plugins/<cap>/plugin.json via parsePluginStrict + compat check
//   2. toolsets.json (search order: <root>, <root>/.mc, first plugin dir)
//      via parseToolsets + toolset_resolver.resolveAll (cycles + unknowns)
//   3. <root>/marketplace.json via parseLibrary (optional — absence ok)
//   4. agents/<name>/agent.json via parseAgent + agent_resolver cross-file
//
// All diagnostics accumulate in one Diagnostics; render once; exit code
// is derived from `diags.hasErrors()`.

const std = @import("std");
const diag = @import("diagnostic");
const plugin_schema = @import("plugin");
const agent_schema = @import("agent");
const toolset_schema = @import("toolset");
const library_schema = @import("library");
const agent_resolver = @import("agent_resolver");
const toolset_resolver = @import("toolset_resolver");
const core_compat = @import("compat");

pub const ValidateOpts = struct {
    // Reserved for future flags (e.g. --json, --strict). No v1 options.
};

/// Result of a validation run. Caller owns via `deinit`.
pub const ValidateResult = struct {
    diags: diag.Diagnostics,
    /// True iff cwd was an mc sandbox (false = graceful skip).
    is_sandbox: bool,

    pub fn deinit(self: *ValidateResult) void {
        self.diags.deinit();
    }

    pub fn hasErrors(self: *const ValidateResult) bool {
        return self.diags.hasErrors();
    }
};

/// Entry point from the CLI dispatcher. Uses process cwd.
/// `opts` is accepted as `anytype` so callers may pass either our own
/// `ValidateOpts` or the `args.ValidateOpts` variant without coupling
/// the two modules.
pub fn execute(allocator: std.mem.Allocator, opts: anytype) !void {
    _ = opts;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    const cwd_owned = try allocator.dupe(u8, cwd);
    defer allocator.free(cwd_owned);

    var result = try runAt(allocator, cwd_owned);
    defer result.deinit();

    if (!result.is_sandbox) {
        const stderr = std.io.getStdErr().writer();
        try stderr.writeAll("Not an mc project. Run 'mc init' first.\n");
        return;
    }

    const stdout = std.io.getStdOut().writer();
    try result.diags.render(stdout);

    if (result.hasErrors()) std.process.exit(1);
}

/// Hermetic test entry: run validation rooted at `project_root`.
/// Returns the full result; caller inspects and cleans up.
pub fn runAt(allocator: std.mem.Allocator, project_root: []const u8) !ValidateResult {
    var diags = diag.Diagnostics.init(allocator);
    errdefer diags.deinit();

    // --- 1. Sandbox gate. Absence is a graceful skip, not an error. ---
    const is_sb = try isSandboxAt(allocator, project_root);
    if (!is_sb) {
        return .{ .diags = diags, .is_sandbox = false };
    }

    // Scratch arena — transient parse buffers, filename strings, etc.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // --- 2. Plugins (schema + compat) ---
    try validatePlugins(allocator, aa, project_root, &diags);

    // --- 3. toolsets.json (schema + graph resolve) ---
    try validateToolsets(allocator, aa, project_root, &diags);

    // --- 4. marketplace.json (schema only; optional) ---
    try validateMarketplace(allocator, aa, project_root, &diags);

    // --- 5. agents (schema + cross-file resolver) ---
    try validateAgents(allocator, aa, project_root, &diags);

    return .{ .diags = diags, .is_sandbox = true };
}

// ---- sandbox check (no dependency on src/core/sandbox.zig which is 0.16) ----

fn isSandboxAt(allocator: std.mem.Allocator, project_root: []const u8) !bool {
    const marker = try std.fmt.allocPrint(allocator, "{s}/.mc/mc.json", .{project_root});
    defer allocator.free(marker);
    std.fs.accessAbsolute(marker, .{}) catch return false;
    return true;
}

// ---- sub-diagnostics merge ----
//
// Strict parsers (plugin/toolset/agent/library) short-circuit on
// `diags.hasErrors()` — meaning one earlier error blinds every later parser.
// To aggregate errors across ALL files in a single pass we give each parse
// call a fresh Diagnostics, then copy its items back into the parent.
// Strings are re-allocated into the parent arena so lifetimes outlive the
// temporary.
fn mergeDiagnostics(parent: *diag.Diagnostics, child: *const diag.Diagnostics) !void {
    const parent_arena = parent.arena.allocator();
    for (child.items.items) |it| {
        const file_copy = try parent_arena.dupe(u8, it.file);
        const path_copy = try parent_arena.dupe(u8, it.path);
        const msg_copy = try parent_arena.dupe(u8, it.message);
        try parent.items.append(.{
            .file = file_copy,
            .path = path_copy,
            .line = it.line,
            .column = it.column,
            .severity = it.severity,
            .message = msg_copy,
        });
    }
}

// ---- plugins ----

fn validatePlugins(
    allocator: std.mem.Allocator,
    aa: std.mem.Allocator,
    project_root: []const u8,
    diags: *diag.Diagnostics,
) !void {
    const plugins_dir_abs = try std.fmt.allocPrint(aa, "{s}/.mc/plugins", .{project_root});

    var dir = std.fs.openDirAbsolute(plugins_dir_abs, .{ .iterate = true }) catch return;
    defer dir.close();

    // detectHostFacts may shell out to `pi`; use the GPA because pi_version
    // is allocated with `allocator.dupe` inside the helper.
    const host = try core_compat.detectHostFacts(allocator);
    defer if (host.pi_version) |pv| allocator.free(pv);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        try validateOnePlugin(allocator, aa, project_root, entry.name, host, diags);
    }
}

fn validateOnePlugin(
    allocator: std.mem.Allocator,
    aa: std.mem.Allocator,
    project_root: []const u8,
    cap_name: []const u8,
    host: core_compat.HostFacts,
    diags: *diag.Diagnostics,
) !void {
    // Try <cap>/plugin.json then <cap>/.claude-plugin/plugin.json.
    const candidates = [_][]const u8{ "plugin.json", ".claude-plugin/plugin.json" };
    for (candidates) |rel| {
        const abs = try std.fmt.allocPrint(
            aa,
            "{s}/.mc/plugins/{s}/{s}",
            .{ project_root, cap_name, rel },
        );
        const src = std.fs.cwd().readFileAlloc(aa, abs, 1 << 20) catch continue;

        const label = try std.fmt.allocPrint(
            aa,
            ".mc/plugins/{s}/{s}",
            .{ cap_name, rel },
        );

        // Isolated diagnostics so a prior file's error doesn't short-circuit
        // this parse via `if (diags.hasErrors()) return null;`.
        var local = diag.Diagnostics.init(allocator);
        defer local.deinit();
        const parsed = try plugin_schema.parsePluginStrict(aa, label, src, &local);
        if (parsed) |p| {
            if (p.compat) |c| {
                _ = try core_compat.checkCompat(c, host, p.name, label, &local);
            }
        }
        try mergeDiagnostics(diags, &local);
        return;
    }
}

// ---- toolsets ----

/// Search order mirrors agent_resolver.findToolsetsJson:
///   1. <root>/toolsets.json
///   2. <root>/.mc/toolsets.json
///   3. First <root>/.mc/plugins/<cap>/toolsets.json
fn validateToolsets(
    allocator: std.mem.Allocator,
    aa: std.mem.Allocator,
    project_root: []const u8,
    diags: *diag.Diagnostics,
) !void {
    const found = try findToolsetsSource(aa, project_root, diags);
    if (found == null) {
        // Warning, not error — agent_resolver also emits a per-agent warning.
        try diags.warn(
            "toolsets.json",
            "",
            "no toolsets.json found in project (checked <root>, <root>/.mc, and plugin dirs)",
            .{},
        );
        return;
    }
    const info = found.?;

    var local = diag.Diagnostics.init(allocator);
    defer local.deinit();

    // parseToolsets allocates the registry's StringHashMap with the given
    // allocator; use the scratch arena so parseFromSliceLeaky buffers and
    // hashmap backing are reclaimed wholesale on arena.deinit.
    const parsed = try toolset_schema.parseToolsets(aa, info.rel_file, info.contents, &local);
    if (parsed) |registry| {
        var reg = registry;
        toolset_resolver.resolveAll(aa, &reg, info.rel_file, &local) catch |e| switch (e) {
            error.UnknownToolset, error.CyclicIncludes => {}, // already reported
            else => return e,
        };
    }
    try mergeDiagnostics(diags, &local);
}

const ToolsetsSource = struct {
    rel_file: []const u8,
    contents: []u8,
};

fn findToolsetsSource(
    aa: std.mem.Allocator,
    project_root: []const u8,
    diags: *diag.Diagnostics,
) !?ToolsetsSource {
    const candidates = [_][]const u8{ "toolsets.json", ".mc/toolsets.json" };
    for (candidates) |rel| {
        const abs = try std.fmt.allocPrint(aa, "{s}/{s}", .{ project_root, rel });
        if (std.fs.cwd().readFileAlloc(aa, abs, 1 << 20)) |data| {
            const label = try diags.arena.allocator().dupe(u8, rel);
            return .{ .rel_file = label, .contents = data };
        } else |_| {}
    }

    const plugins_dir_abs = try std.fmt.allocPrint(aa, "{s}/.mc/plugins", .{project_root});
    var plugins_dir = std.fs.openDirAbsolute(plugins_dir_abs, .{ .iterate = true }) catch return null;
    defer plugins_dir.close();

    var it = plugins_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const abs = try std.fmt.allocPrint(
            aa,
            "{s}/{s}/toolsets.json",
            .{ plugins_dir_abs, entry.name },
        );
        if (std.fs.cwd().readFileAlloc(aa, abs, 1 << 20)) |data| {
            const label = try std.fmt.allocPrint(
                diags.arena.allocator(),
                ".mc/plugins/{s}/toolsets.json",
                .{entry.name},
            );
            return .{ .rel_file = label, .contents = data };
        } else |_| {}
    }
    return null;
}

// ---- marketplace ----

fn validateMarketplace(
    allocator: std.mem.Allocator,
    aa: std.mem.Allocator,
    project_root: []const u8,
    diags: *diag.Diagnostics,
) !void {
    const abs = try std.fmt.allocPrint(aa, "{s}/marketplace.json", .{project_root});
    const src = std.fs.cwd().readFileAlloc(aa, abs, 1 << 20) catch return; // absent is OK
    const label = "marketplace.json";

    var local = diag.Diagnostics.init(allocator);
    defer local.deinit();
    _ = try library_schema.parseLibrary(aa, label, src, &local);
    try mergeDiagnostics(diags, &local);
}

// ---- agents ----

fn validateAgents(
    allocator: std.mem.Allocator,
    aa: std.mem.Allocator,
    project_root: []const u8,
    diags: *diag.Diagnostics,
) !void {
    const agents_dir_abs = try std.fmt.allocPrint(aa, "{s}/agents", .{project_root});
    var agents_dir = std.fs.openDirAbsolute(agents_dir_abs, .{ .iterate = true }) catch return;
    defer agents_dir.close();

    var it = agents_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        // Isolated diagnostics per agent so a prior file's errors don't
        // short-circuit `parseAgent`'s strict schema pass.
        var local = diag.Diagnostics.init(allocator);
        defer local.deinit();
        _ = try agent_resolver.validateAgentInProject(allocator, project_root, entry.name, &local);
        try mergeDiagnostics(diags, &local);
    }
}
