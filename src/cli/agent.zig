const std = @import("std");
const compat = @import("../io/compat.zig");
const args_mod = @import("args.zig");
const render = @import("render.zig");

pub fn execute(allocator: std.mem.Allocator, sub: args_mod.AgentSub) !void {
    switch (sub) {
        .new => |opts| try executeNew(allocator, opts),
    }
}

fn executeNew(allocator: std.mem.Allocator, opts: args_mod.AgentNewOpts) !void {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.posix.getcwd(&cwd_buf);
    const cwd_dup = try allocator.dupe(u8, cwd);

    var w = compat.getStdout();
    const res = try scaffoldAt(allocator, cwd_dup, opts);
    reportScaffold(&w, opts.name, res);
    w.flush();
}

pub const ScaffoldResult = enum {
    created,
    not_a_sandbox,
    invalid_name,
    already_exists,
};

/// Pure filesystem scaffolder. Uses std.fs directly so tests can drive it
/// without pulling in the compat layer. Does not print — callers handle UX.
pub fn scaffoldAt(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    opts: args_mod.AgentNewOpts,
) !ScaffoldResult {
    var root_dir = std.fs.openDirAbsolute(project_dir, .{}) catch return .not_a_sandbox;
    defer root_dir.close();

    // Sandbox check: .mc/mc.json must exist under project_dir.
    if (root_dir.access(".mc/mc.json", .{})) |_| {} else |_| return .not_a_sandbox;

    if (!isValidSlug(opts.name)) return .invalid_name;

    // Create agents/ (idempotent) and agents/<name>/ (must not exist).
    root_dir.makeDir("agents") catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var agents_dir = try root_dir.openDir("agents", .{});
    defer agents_dir.close();

    // Refuse to overwrite.
    if (agents_dir.access(opts.name, .{})) |_| {
        return .already_exists;
    } else |_| {}

    try agents_dir.makeDir(opts.name);
    var agent_dir = try agents_dir.openDir(opts.name, .{});
    defer agent_dir.close();

    try agent_dir.makeDir("overrides");
    var overrides_dir = try agent_dir.openDir("overrides", .{});
    defer overrides_dir.close();
    try overrides_dir.writeFile(.{ .sub_path = ".gitkeep", .data = "" });

    const prompt = try renderPrompt(allocator, opts.name);
    defer allocator.free(prompt);
    try agent_dir.writeFile(.{ .sub_path = "prompt.md", .data = prompt });

    const agent_json = try renderAgentJson(allocator, opts);
    defer allocator.free(agent_json);
    try agent_dir.writeFile(.{ .sub_path = "agent.json", .data = agent_json });

    return .created;
}

fn reportScaffold(w: *compat.OutWriter, name: []const u8, res: ScaffoldResult) void {
    switch (res) {
        .not_a_sandbox => {
            render.err(w, "Not an mc project");
            w.writeAll(". Run 'mc init' first.\n");
        },
        .invalid_name => {
            render.err(w, "Invalid agent name");
            w.print(": '{s}'\n", .{name});
            w.writeAll("Name must match ^[a-z][a-z0-9-]{0,62}$ (lowercase slug, e.g. 'my-agent').\n");
        },
        .already_exists => {
            render.err(w, "Agent already exists");
            w.print(": agents/{s}\n", .{name});
        },
        .created => {
            render.success(w, "Created");
            w.print(" agents/{s}/\n", .{name});
            w.writeAll("  \xe2\x94\x9c\xe2\x94\x80 agent.json  (composition \xe2\x80\x94 edit capabilities/toolset/model)\n");
            w.writeAll("  \xe2\x94\x9c\xe2\x94\x80 prompt.md   (agent system prompt)\n");
            w.writeAll("  \xe2\x94\x94\xe2\x94\x80 overrides/  (optional file-level overrides)\n");
            w.writeAll("\nNext steps:\n");
            w.print("  1. Edit agents/{s}/prompt.md to define the agent's role.\n", .{name});
            w.print("  2. Edit agents/{s}/agent.json to declare its capabilities.\n", .{name});
            w.print("  3. Run: mc run {s} -p \"...\"  (when phase 8 lands)\n", .{name});
        },
    }
}

/// Slug: `^[a-z][a-z0-9-]{0,62}$`.
pub fn isValidSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 63) return false;
    if (s[0] < 'a' or s[0] > 'z') return false;
    for (s[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn renderPrompt(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    // Title-case: first char upper, rest lower (simple, non-clever).
    var title = try allocator.alloc(u8, name.len);
    defer allocator.free(title);
    title[0] = std.ascii.toUpper(name[0]);
    for (name[1..], 1..) |c, i| title[i] = std.ascii.toLower(c);

    return std.fmt.allocPrint(
        allocator,
        \\# {s} Agent
        \\
        \\TODO: write the system prompt for this agent. Describe:
        \\
        \\- Role — what this agent is (e.g. "code reviewer", "deployer")
        \\- Responsibilities — what it does
        \\- Tone / style — how it communicates
        \\- Boundaries — what it does NOT do
        \\
        \\Keep it focused. The agent's capabilities are declared in `agent.json`; this file is purely the prose role definition.
        \\
    ,
        .{title},
    );
}

pub fn renderAgentJson(allocator: std.mem.Allocator, opts: args_mod.AgentNewOpts) ![]u8 {
    const model = opts.model orelse "claude-haiku-4.5";
    const provider = opts.provider orelse "openrouter";
    const toolset = opts.toolset orelse "read-only";

    return std.fmt.allocPrint(
        allocator,
        \\{{
        \\  "name": "{s}",
        \\  "description": "TODO: one-line description of what this agent does",
        \\  "model": "{s}",
        \\  "provider": "{s}",
        \\  "thinking": "medium",
        \\  "prompt": "./prompt.md",
        \\  "capabilities": {{
        \\    "skills": [],
        \\    "commands": [],
        \\    "extensions": [],
        \\    "toolset": "{s}"
        \\  }},
        \\  "env": {{
        \\    "required": [],
        \\    "optional": []
        \\  }}
        \\}}
        \\
    ,
        .{ opts.name, model, provider, toolset },
    );
}
