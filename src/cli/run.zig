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
const compat = @import("iocompat");
const emit = @import("emit");

pub const RunOpts = struct {
    agent_name: []const u8,
    dry_run: bool = false,
    extra_args: []const []const u8 = &.{},
    /// Standalone mode: load the agent from this lone agent.json (no `.mc`
    /// sandbox; toolset resolved from a sibling toolsets.json or the agent's
    /// pre-resolved `capabilities.toolset` ids; skills are pre-staged dirs).
    file: ?[]const u8 = null,
    /// Print the exact pi argv as a single JSON array of strings, and exit.
    print_argv: bool = false,
};

/// Output of the pure resolution pipeline.  Owns an arena for all strings.
pub const ResolvedCommand = struct {
    arena: std.heap.ArenaAllocator,
    /// Full pi argv (argv[0] == "pi").
    argv: []const []const u8,
    /// System-prompt text (the value that appears in argv after "--system-prompt").
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
    env_override: ?*const std.StringHashMap([]const u8),
) !ResolvedCommand {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Standalone mode: a lone agent.json with no `.mc` sandbox. Skips the
    // marker, cross-file validate and materialize; resolves the toolset from a
    // sibling toolsets.json (or treats `capabilities.toolset` as a pre-resolved
    // tool id when absent) and points pi at PRE-STAGED skill/extension dirs.
    if (opts.file) |file_path| {
        return buildCommandFromFile(&arena, file_path, opts, diags, env_override);
    }

    // 1. sandbox
    const mc_marker = try std.fmt.allocPrint(a, "{s}/.mc/mc.json", .{project_root});
    compat.accessAbsolute(mc_marker) catch {
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
        var d = compat.openDirAbsoluteNoIter(agent_dir) catch {
            try diags.err(agent_file_rel, "", "agent directory not found: {s}", .{agent_dir});
            return error.AgentDirMissing;
        };
        d.close(compat.getIo());
    }

    const src = compat.readFile(a, agent_file_abs) catch {
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
    var missing: std.ArrayList([]const u8) = .empty;
    var env_ok = true;
    for (agent.env.required) |name| {
        if (!envHas(a, name, env_override)) {
            env_ok = false;
            try missing.append(a, try a.dupe(u8, name));
            try diags.err(agent_file_rel, "env.required", "required env var not set: {s}", .{name});
        }
    }
    if (!env_ok) return error.MissingRequiredEnv;

    // 7. prompt content
    const prompt_abs = try std.fs.path.join(a, &.{ agent_dir, agent.prompt });
    const prompt_text = compat.readFile(a, prompt_abs) catch {
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

    // 9. assemble pi argv via the single canonical builder (emit.emitPiArgv).
    // One --skill <runtime_dir>/<cap> per materialized capability.
    var skill_dirs = try a.alloc([]const u8, cap_names.len);
    for (cap_names, 0..) |cap, i| {
        skill_dirs[i] = try std.fs.path.join(a, &.{ runtime_dir, cap });
    }
    const argv = try emit.emitPiArgv(a, agent, tools, skill_dirs, prompt_text, opts.extra_args);

    return ResolvedCommand{
        .arena = arena,
        .argv = argv,
        .prompt = prompt_text,
        .runtime_dir = runtime_dir,
        .env_ok = env_ok,
        .missing_env = try missing.toOwnedSlice(a),
    };
}

/// Public runner — performs dry-run printing or exec-replaces the current
/// process with `pi`.  On success with `dry_run = false`, this function does
/// not return.
pub fn execute(allocator: std.mem.Allocator, opts: RunOpts) !void {
    // Resolve cwd → absolute project_root.
    const cwd_abs = try compat.getCwdAlloc(allocator);
    defer allocator.free(cwd_abs);

    var diags = diag.Diagnostics.init(allocator);
    defer diags.deinit();

    var cmd = buildCommand(allocator, cwd_abs, opts, &diags, null) catch |e| {
        // Render whatever diagnostics accumulated.
        var ew = compat.getStderr();
        diags.render(&ew.file_writer.interface) catch {};
        ew.flush();
        return e;
    };
    defer cmd.deinit();

    // Render any warnings (no errors, else buildCommand would have failed).
    if (diags.count() > 0) {
        var ew = compat.getStderr();
        diags.render(&ew.file_writer.interface) catch {};
        ew.flush();
    }

    if (opts.print_argv) {
        try printArgv(allocator, cmd);
        return;
    }

    if (opts.dry_run) {
        try printDryRun(cmd);
        return;
    }

    // Run pi inheriting stdio, then exit with its code (spawn+wait replaces
    // the old exec-replace; std.process.execv is gone in this std).
    const code = try compat.execReplace(cmd.argv);
    std.process.exit(code);
}

// ---------------------------------------------------------------------------
// argv assembly
// ---------------------------------------------------------------------------

/// Standalone resolution from a lone agent.json (`mc run --file <path>`): no
/// `.mc` sandbox, no cross-file validate, no materialize. Toolset is resolved
/// from a sibling `toolsets.json` if present; otherwise the agent's
/// `capabilities.toolset` is treated as a single pre-resolved tool id. Skills
/// and extensions are PRE-STAGED dirs handed straight to pi via `--skill`
/// (absolute verbatim, relative resolved against the file's dir) — no package
/// manager is invoked.
fn buildCommandFromFile(
    arena: *std.heap.ArenaAllocator,
    file_path: []const u8,
    opts: RunOpts,
    diags: *diag.Diagnostics,
    env_override: ?*const std.StringHashMap([]const u8),
) !ResolvedCommand {
    const a = arena.allocator();

    const file_abs = if (std.fs.path.isAbsolute(file_path))
        try a.dupe(u8, file_path)
    else blk: {
        const cwd = try compat.getCwdAlloc(a);
        break :blk try std.fs.path.join(a, &.{ cwd, file_path });
    };
    const file_dir = std.fs.path.dirname(file_abs) orelse ".";
    const rel_label = try diags.arena.allocator().dupe(u8, file_path);

    const src = compat.readFile(a, file_abs) catch {
        try diags.err(rel_label, "", "agent.json not found or unreadable: {s}", .{file_abs});
        return error.AgentFileMissing;
    };

    const agent = (try agent_schema.parseAgent(a, rel_label, src, diags)) orelse
        return error.AgentParseFailed;

    // Toolset: a sibling toolsets.json if present, else treat
    // capabilities.toolset as a single already-resolved tool id.
    var tools: []const []const u8 = undefined;
    const sibling_ts = try std.fs.path.join(a, &.{ file_dir, "toolsets.json" });
    if (compat.readFile(a, sibling_ts)) |ts_contents| {
        const ts_label = try a.dupe(u8, "toolsets.json");
        const registry_opt = try toolset_schema.parseToolsets(a, ts_label, ts_contents, diags);
        if (registry_opt == null) return error.ToolsetsParseFailed;
        var registry = registry_opt.?;
        defer registry.deinit();
        tools = toolset_resolver.resolve(a, &registry, agent.capabilities.toolset, ts_label, diags) catch
            return error.ToolsetResolveFailed;
    } else |_| {
        // No sibling registry: the toolset name IS the pre-resolved tool id.
        const one = try a.alloc([]const u8, 1);
        one[0] = agent.capabilities.toolset;
        tools = one;
    }

    // env var check (identical policy to sandbox mode).
    var missing: std.ArrayList([]const u8) = .empty;
    var env_ok = true;
    for (agent.env.required) |name| {
        if (!envHas(a, name, env_override)) {
            env_ok = false;
            try missing.append(a, try a.dupe(u8, name));
            try diags.err(rel_label, "env.required", "required env var not set: {s}", .{name});
        }
    }
    if (!env_ok) return error.MissingRequiredEnv;

    // prompt content (system prompt), resolved relative to the file's dir.
    const prompt_abs = try std.fs.path.join(a, &.{ file_dir, agent.prompt });
    const prompt_text = compat.readFile(a, prompt_abs) catch {
        try diags.err(rel_label, "prompt", "prompt file not readable: {s}", .{prompt_abs});
        return error.PromptFileMissing;
    };

    // Pre-staged skill/extension dirs → one --skill each (absolute verbatim,
    // relative resolved against the file's dir). No materialize, no downloads.
    var skill_list: std.ArrayList([]const u8) = .empty;
    for (agent.capabilities.skills) |s| try appendStagedDir(a, &skill_list, file_dir, s);
    for (agent.capabilities.extensions) |e| try appendStagedDir(a, &skill_list, file_dir, e);
    const skill_dirs = try skill_list.toOwnedSlice(a);

    const argv = try emit.emitPiArgv(a, agent, tools, skill_dirs, prompt_text, opts.extra_args);

    return ResolvedCommand{
        .arena = arena.*,
        .argv = argv,
        .prompt = prompt_text,
        .runtime_dir = try a.dupe(u8, file_dir),
        .env_ok = env_ok,
        .missing_env = try missing.toOwnedSlice(a),
    };
}

fn appendStagedDir(
    a: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    base_dir: []const u8,
    entry: []const u8,
) !void {
    const dir = if (std.fs.path.isAbsolute(entry))
        try a.dupe(u8, entry)
    else
        try std.fs.path.join(a, &.{ base_dir, entry });
    try list.append(a, dir);
}

// The pi argv is built by the single canonical builder `emit.emitPiArgv`
// (src/core/emit.zig) so `mc run` and `mc agent emit` never diverge.

// ---------------------------------------------------------------------------
// env lookup (process env or override)
// ---------------------------------------------------------------------------

fn envHas(
    allocator: std.mem.Allocator,
    name: []const u8,
    env_override: ?*const std.StringHashMap([]const u8),
) bool {
    _ = allocator;
    if (env_override) |m| return m.get(name) != null;
    return compat.hasEnvVar(name);
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
        if (compat.readFile(a, abs)) |data| {
            return .{ .rel_label = try a.dupe(u8, rel), .contents = data };
        } else |_| {}
    }

    const plugins = try std.fmt.allocPrint(a, "{s}/.mc/plugins", .{project_root});
    var dir = compat.openDirAbsolute(plugins) catch return null;
    defer dir.close(compat.getIo());
    var it = compat.iterateDir(dir);
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const abs = try std.fmt.allocPrint(a, "{s}/{s}/toolsets.json", .{ plugins, entry.name });
        if (compat.readFile(a, abs)) |data| {
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
    var ow = compat.getStdout();
    defer ow.flush();
    const stdout = &ow.file_writer.interface;
    try stdout.writeAll("# pi command (dry-run)\n");
    // Mask the element FOLLOWING `--system-prompt` (the long literal system
    // prompt) by content/position — never a fixed index, since the system
    // prompt is no longer at argv[2].
    var mask_next = false;
    for (cmd.argv) |arg| {
        if (mask_next) {
            try stdout.writeAll("<PROMPT>\n");
            mask_next = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--system-prompt")) mask_next = true;
        try writeShellQuoted(stdout, arg);
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("\n# system prompt text:\n");
    try stdout.writeAll(cmd.prompt);
    if (cmd.prompt.len == 0 or cmd.prompt[cmd.prompt.len - 1] != '\n')
        try stdout.writeAll("\n");
}

/// Machine-readable argv dump for an external runner: a single JSON array of
/// strings (the runner `JSON.parse`s it). Raw — NOT shell-quoted, NOT masked;
/// the runner execs the array verbatim, so faithfulness (the full
/// --system-prompt text) wins over copy-paste safety (that is `--dry-run`).
/// A newline-delimited dump would corrupt any element that itself contains a
/// newline (e.g. a multi-line system prompt or @task contents).
fn printArgv(allocator: std.mem.Allocator, cmd: ResolvedCommand) !void {
    var ow = compat.getStdout();
    defer ow.flush();
    const stdout = &ow.file_writer.interface;
    const json = try std.json.Stringify.valueAlloc(allocator, cmd.argv, .{});
    defer allocator.free(json);
    try stdout.writeAll(json);
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
