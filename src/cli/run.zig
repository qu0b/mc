//! Phase 8: `mc run <agent>` — end-to-end agent invocation pipeline.
//!
//! Pipeline:
//!   1. sandbox check
//!   2. parse agent.json
//!   3. cross-file validate (agent_resolver)
//!   4. load + resolve toolset
//!   5. env var check
//!   6. materialize capabilities + write trace
//!   7. assemble pi argv
//!   8. exec-replace (std.process.execv) or print (dry-run)
//!
//! The impure `execute()` is a thin wrapper around the pure `buildCommand()`
//! so tests can assert argv shape without touching exec.

const std = @import("std");
const diag = @import("diagnostic");
const agent_schema = @import("agent");
const toolset_schema = @import("toolset");
const agent_resolver = @import("agent_resolver");
const toolset_resolver = @import("toolset_resolver");
const materialize = @import("materialize");

pub const RunOpts = struct {
    agent_name: []const u8,
    dry_run: bool = false,
    extra_args: []const []const u8 = &.{},
};

/// Output of the pure resolution pipeline.  Owns an arena for all strings.
pub const ResolvedCommand = struct {
    arena: std.heap.ArenaAllocator,
    /// Full pi argv (argv[0] == "pi").
    argv: []const []const u8,
    /// Prompt text (same value that appears in argv after "-p").
    prompt: []const u8,
    /// Absolute path to <project_root>/.mc/runtime/<agent>/
    runtime_dir: []const u8,
    /// Whether required env vars were all present.
    env_ok: bool,
    /// Names of required env vars that were not set.
    missing_env: []const []const u8,

    pub fn deinit(self: *ResolvedCommand) void {
        self.arena.deinit();
    }
};

pub const BuildError = error{
    NotASandbox,
    AgentDirMissing,
    AgentFileMissing,
    AgentParseFailed,
    AgentValidationFailed,
    ToolsetsNotFound,
    ToolsetsParseFailed,
    ToolsetResolveFailed,
    PromptFileMissing,
    MaterializeFailed,
    MissingRequiredEnv,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.Dir.RealPathError;

/// Pure pipeline: no exec, no stdout writes for success.  Diagnostics go to `diags`.
///
/// `env_override` — when non-null, used instead of the process environment to
/// check required env vars (tests).
pub fn buildCommand(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    opts: RunOpts,
    diags: *diag.Diagnostics,
    env_override: ?*const std.process.EnvMap,
) !ResolvedCommand {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // 1. sandbox
    const mc_marker = try std.fmt.allocPrint(a, "{s}/.mc/mc.json", .{project_root});
    std.fs.accessAbsolute(mc_marker, .{}) catch {
        try diags.err(project_root, "", "not an mc sandbox (no .mc/mc.json)", .{});
        return error.NotASandbox;
    };

    // 2. paths + agent.json
    const agent_dir = try std.fmt.allocPrint(a, "{s}/agents/{s}", .{ project_root, opts.agent_name });
    const agent_file_abs = try std.fmt.allocPrint(a, "{s}/agent.json", .{agent_dir});
    const agent_file_rel = try std.fmt.allocPrint(
        diags.arena.allocator(),
        "agents/{s}/agent.json",
        .{opts.agent_name},
    );

    // Agent dir must exist.
    {
        var d = std.fs.openDirAbsolute(agent_dir, .{}) catch {
            try diags.err(agent_file_rel, "", "agent directory not found: {s}", .{agent_dir});
            return error.AgentDirMissing;
        };
        d.close();
    }

    const src = std.fs.cwd().readFileAlloc(a, agent_file_abs, 1 << 20) catch {
        try diags.err(agent_file_rel, "", "agent.json not found or unreadable", .{});
        return error.AgentFileMissing;
    };

    // 3. parse agent
    const maybe_agent = try agent_schema.parseAgent(a, agent_file_rel, src, diags);
    const agent = maybe_agent orelse return error.AgentParseFailed;

    // 4. cross-file validate
    const validate_ok = try agent_resolver.validateAgentInProject(
        allocator,
        project_root,
        opts.agent_name,
        diags,
    );
    if (!validate_ok) return error.AgentValidationFailed;

    // 5. toolset: locate + parse + resolve
    const ts_info = try findToolsetsJson(a, project_root);
    if (ts_info == null) {
        const p = try diags.arena.allocator().dupe(u8, "capabilities.toolset");
        try diags.err(agent_file_rel, p, "no toolsets.json found (required for `mc run`)", .{});
        return error.ToolsetsNotFound;
    }

    const registry_opt = try toolset_schema.parseToolsets(
        a,
        ts_info.?.rel_label,
        ts_info.?.contents,
        diags,
    );
    if (registry_opt == null) return error.ToolsetsParseFailed;
    var registry = registry_opt.?;
    // Registry lives in arena-backed memory but owns a StringHashMap;
    // we must deinit that explicitly to free its backing bucket array.
    defer registry.deinit();

    const tools = toolset_resolver.resolve(
        a,
        &registry,
        agent.capabilities.toolset,
        ts_info.?.rel_label,
        diags,
    ) catch return error.ToolsetResolveFailed;

    // 6. env var check
    var missing = std.ArrayList([]const u8).init(a);
    var env_ok = true;
    for (agent.env.required) |name| {
        if (!envHas(a, name, env_override)) {
            env_ok = false;
            try missing.append(try a.dupe(u8, name));
            try diags.err(agent_file_rel, "env.required", "required env var not set: {s}", .{name});
        }
    }
    if (!env_ok) return error.MissingRequiredEnv;

    // 7. prompt content
    const prompt_abs = try std.fs.path.join(a, &.{ agent_dir, agent.prompt });
    const prompt_text = std.fs.cwd().readFileAlloc(a, prompt_abs, 1 << 22) catch {
        try diags.err(agent_file_rel, "prompt", "prompt file not readable: {s}", .{prompt_abs});
        return error.PromptFileMissing;
    };

    // 8. materialize capabilities.
    var mat = materialize.materializeAgent(allocator, project_root, agent, diags) catch |e| {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.MaterializeFailed,
        };
    };
    // writeTrace is best-effort — don't fail the run on it.
    materialize.writeTrace(mat, allocator) catch {
        diags.warn(agent_file_rel, "", "failed to write trace.json (non-fatal)", .{}) catch {};
    };
    // Capture everything we need from mat into our arena before releasing it.
    const runtime_dir = try a.dupe(u8, mat.runtime_dir);
    // Collect the materialized capability names (already sorted, deduped).
    var cap_names = try a.alloc([]const u8, mat.cap_names.len);
    for (mat.cap_names, 0..) |n, i| cap_names[i] = try a.dupe(u8, n);
    mat.deinit();

    // 9. assemble pi argv.
    const argv = try assembleArgv(a, agent, tools, runtime_dir, cap_names, prompt_text, opts.extra_args);

    return ResolvedCommand{
        .arena = arena,
        .argv = argv,
        .prompt = prompt_text,
        .runtime_dir = runtime_dir,
        .env_ok = env_ok,
        .missing_env = try missing.toOwnedSlice(),
    };
}

/// Public runner — performs dry-run printing or exec-replaces the current
/// process with `pi`.  On success with `dry_run = false`, this function does
/// not return.
pub fn execute(allocator: std.mem.Allocator, opts: RunOpts) !void {
    // Resolve cwd → absolute project_root.
    const cwd_abs = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_abs);

    var diags = diag.Diagnostics.init(allocator);
    defer diags.deinit();

    var cmd = buildCommand(allocator, cwd_abs, opts, &diags, null) catch |e| {
        // Render whatever diagnostics accumulated.
        const stderr = std.io.getStdErr().writer();
        diags.render(stderr) catch {};
        return e;
    };
    defer cmd.deinit();

    // Render any warnings (no errors, else buildCommand would have failed).
    if (diags.count() > 0) {
        const stderr = std.io.getStdErr().writer();
        diags.render(stderr) catch {};
    }

    if (opts.dry_run) {
        try printDryRun(cmd);
        return;
    }

    // Exec-replace.  execv never returns on success.
    return std.process.execv(allocator, cmd.argv);
}

// ---------------------------------------------------------------------------
// argv assembly
// ---------------------------------------------------------------------------

fn assembleArgv(
    a: std.mem.Allocator,
    agent: agent_schema.Agent,
    tools: []const []const u8,
    runtime_dir: []const u8,
    cap_names: []const []const u8,
    prompt_text: []const u8,
    extra: []const []const u8,
) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(a);

    try list.append(try a.dupe(u8, "pi"));

    try list.append(try a.dupe(u8, "-p"));
    try list.append(try a.dupe(u8, prompt_text));

    try list.append(try a.dupe(u8, "--provider"));
    try list.append(try a.dupe(u8, agent.provider));

    try list.append(try a.dupe(u8, "--model"));
    try list.append(try a.dupe(u8, agent.model));

    try list.append(try a.dupe(u8, "--thinking"));
    try list.append(try a.dupe(u8, agent.thinking));

    try list.append(try a.dupe(u8, "--tools"));
    try list.append(try joinCSV(a, tools));

    // Explicit loadout: never auto-load other skills/extensions.
    try list.append(try a.dupe(u8, "--no-skills"));
    try list.append(try a.dupe(u8, "--no-extensions"));

    // One --skill <runtime_dir>/<cap> per materialized capability.
    for (cap_names) |cap| {
        try list.append(try a.dupe(u8, "--skill"));
        try list.append(try std.fs.path.join(a, &.{ runtime_dir, cap }));
    }

    for (extra) |e| try list.append(try a.dupe(u8, e));

    return list.toOwnedSlice();
}

fn joinCSV(a: std.mem.Allocator, items: []const []const u8) ![]u8 {
    if (items.len == 0) return a.dupe(u8, "");
    var total: usize = 0;
    for (items) |it| total += it.len;
    total += items.len - 1; // separators
    var buf = try a.alloc(u8, total);
    var p: usize = 0;
    for (items, 0..) |it, i| {
        if (i > 0) {
            buf[p] = ',';
            p += 1;
        }
        @memcpy(buf[p .. p + it.len], it);
        p += it.len;
    }
    return buf;
}

// ---------------------------------------------------------------------------
// env lookup (process env or override)
// ---------------------------------------------------------------------------

fn envHas(
    allocator: std.mem.Allocator,
    name: []const u8,
    env_override: ?*const std.process.EnvMap,
) bool {
    if (env_override) |m| return m.get(name) != null;
    const v = std.process.getEnvVarOwned(allocator, name) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return false,
        else => return false,
    };
    allocator.free(v);
    return true;
}

// ---------------------------------------------------------------------------
// toolsets.json discovery (mirrors agent_resolver order)
// ---------------------------------------------------------------------------

const ToolsetsSource = struct {
    rel_label: []const u8, // for diagnostics
    contents: []u8,
};

fn findToolsetsJson(
    a: std.mem.Allocator,
    project_root: []const u8,
) !?ToolsetsSource {
    const candidates = [_][]const u8{ "toolsets.json", ".mc/toolsets.json" };
    for (candidates) |rel| {
        const abs = try std.fmt.allocPrint(a, "{s}/{s}", .{ project_root, rel });
        if (std.fs.cwd().readFileAlloc(a, abs, 1 << 20)) |data| {
            return .{ .rel_label = try a.dupe(u8, rel), .contents = data };
        } else |_| {}
    }

    const plugins = try std.fmt.allocPrint(a, "{s}/.mc/plugins", .{project_root});
    var dir = std.fs.openDirAbsolute(plugins, .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const abs = try std.fmt.allocPrint(a, "{s}/{s}/toolsets.json", .{ plugins, entry.name });
        if (std.fs.cwd().readFileAlloc(a, abs, 1 << 20)) |data| {
            const label = try std.fmt.allocPrint(a, ".mc/plugins/{s}/toolsets.json", .{entry.name});
            return .{ .rel_label = label, .contents = data };
        } else |_| {}
    }
    return null;
}

// ---------------------------------------------------------------------------
// dry-run rendering
// ---------------------------------------------------------------------------

fn printDryRun(cmd: ResolvedCommand) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("# pi command (dry-run)\n");
    for (cmd.argv, 0..) |arg, i| {
        // For the prompt value (argv[2] after "pi", "-p") we print a short
        // placeholder for readability and dump the full prompt separately.
        if (i == 2) {
            try stdout.writeAll("<PROMPT>\n");
            continue;
        }
        try writeShellQuoted(stdout, arg);
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("\n# prompt text:\n");
    try stdout.writeAll(cmd.prompt);
    if (cmd.prompt.len == 0 or cmd.prompt[cmd.prompt.len - 1] != '\n')
        try stdout.writeAll("\n");
}

/// Render an argv element safely for human copy-paste.  If it contains any
/// char outside a conservative safe set, wrap in single quotes and escape
/// embedded quotes `'` → `'\''`.  Empty strings are rendered as `''`.
pub fn writeShellQuoted(writer: anytype, s: []const u8) !void {
    if (s.len == 0) {
        try writer.writeAll("''");
        return;
    }
    var safe = true;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '/' or c == '.' or c == '_' or c == '-' or c == '=' or c == ':' or c == ',' or c == '+';
        if (!ok) {
            safe = false;
            break;
        }
    }
    if (safe) {
        try writer.writeAll(s);
        return;
    }
    try writer.writeAll("'");
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(s[i]);
        }
    }
    try writer.writeAll("'");
}
