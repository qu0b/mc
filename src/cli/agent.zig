const std = @import("std");
const compat = @import("../io/compat.zig");
const args_mod = @import("args.zig");
const render = @import("render.zig");

pub fn execute(allocator: std.mem.Allocator, sub: args_mod.AgentSub) !void {
    switch (sub) {
        .new => |opts| try executeNew(allocator, opts),
        .show => |opts| try executeShow(allocator, opts),
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

// ============================================================
// `mc agent show <name>` — trace renderer
// ============================================================

/// Outcome of executeShowAt / executeShowWriter.
pub const ShowResult = enum {
    ok,
    not_a_sandbox,
    no_trace,
};

/// Production entry point. Resolves cwd, writes to stdout.
fn executeShow(allocator: std.mem.Allocator, opts: args_mod.AgentShowOpts) !void {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.posix.getcwd(&cwd_buf);
    const cwd_dup = try allocator.dupe(u8, cwd);
    defer allocator.free(cwd_dup);

    var w = compat.getStdout();
    // Use the underlying std.io.Writer interface so executeShowWriter can use `try`.
    _ = try executeShowWriter(allocator, cwd_dup, opts.name, &w.file_writer.interface);
    w.flush();
}

/// Test-friendly variant: caller provides project_root and a writer.
/// The writer must be a `std.io.Writer`-compatible sink (supports
/// `try writer.writeAll(...)` and `try writer.print(fmt, args)`).
pub fn executeShowWriter(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    name: []const u8,
    writer: anytype,
) !ShowResult {
    // 1. Sandbox check.
    {
        var root_dir = std.fs.openDirAbsolute(project_root, .{}) catch {
            try writer.writeAll("Not an mc project\n");
            return .not_a_sandbox;
        };
        defer root_dir.close();
        root_dir.access(".mc/mc.json", .{}) catch {
            try writer.writeAll("Not an mc project\n");
            return .not_a_sandbox;
        };
    }

    // 2. Locate trace.json.
    const trace_path = try std.fs.path.join(allocator, &.{
        project_root, ".mc", "runtime", name, "trace.json",
    });
    defer allocator.free(trace_path);

    const bytes = std.fs.cwd().readFileAlloc(allocator, trace_path, 8 * 1024 * 1024) catch |e| switch (e) {
        error.FileNotFound => {
            try writer.print(
                \\No runtime trace for agent '{s}'.
                \\Materialize first with:   mc run {s} --dry-run
                \\
            , .{ name, name });
            return .no_trace;
        },
        else => return e,
    };
    defer allocator.free(bytes);

    // 3. Parse trace.json under an arena (leaky JSON parser is fine inside it).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{
        .allocate = .alloc_if_needed,
    });
    if (parsed != .object) return error.InvalidTrace;
    const root = parsed.object;

    const agent_name = if (root.get("agent")) |v|
        (if (v == .string) v.string else name)
    else
        name;
    const generated_at = if (root.get("generated_at")) |v|
        (if (v == .string) v.string else "")
    else
        "";

    try writer.print("Agent: {s}\n", .{agent_name});
    if (generated_at.len > 0) {
        try writer.print("Generated: {s}\n", .{generated_at});
    }
    try writer.print("Runtime:  .mc/runtime/{s}/\n\n", .{name});

    var total_library: usize = 0;
    var total_project: usize = 0;
    var total_agent: usize = 0;

    const caps_val = root.get("capabilities") orelse {
        try writer.writeAll("Files by layer: 0 library, 0 project, 0 agent\n");
        return .ok;
    };
    if (caps_val != .array) return error.InvalidTrace;
    const caps = caps_val.array;

    var cap_i: usize = 0;
    while (cap_i < caps.items.len) : (cap_i += 1) {
        const cap_v = caps.items[cap_i];
        if (cap_v != .object) continue;
        const cap_obj = cap_v.object;

        const cap_name_v = cap_obj.get("name") orelse continue;
        if (cap_name_v != .string) continue;
        const cap_name = cap_name_v.string;

        const version_v = cap_obj.get("library_version");
        const version_str: ?[]const u8 = blk: {
            if (version_v) |v| {
                if (v == .string) break :blk v.string;
            }
            break :blk null;
        };

        if (version_str) |ver| {
            try writer.print("{s} (library v{s})\n", .{ cap_name, ver });
        } else {
            try writer.print("{s} (library)\n", .{cap_name});
        }

        const files_v = cap_obj.get("files") orelse {
            if (cap_i + 1 < caps.items.len) try writer.writeAll("\n");
            continue;
        };
        if (files_v != .array) continue;
        const files = files_v.array;

        var fi: usize = 0;
        while (fi < files.items.len) : (fi += 1) {
            const f_v = files.items[fi];
            if (f_v != .object) continue;
            const f = f_v.object;

            const path_v = f.get("path") orelse continue;
            const layer_v = f.get("layer") orelse continue;
            if (path_v != .string or layer_v != .string) continue;

            const path = path_v.string;
            const layer = layer_v.string;

            if (std.mem.eql(u8, layer, "library")) total_library += 1
            else if (std.mem.eql(u8, layer, "project")) total_project += 1
            else if (std.mem.eql(u8, layer, "agent")) total_agent += 1;

            const is_last = (fi + 1 == files.items.len);
            const branch: []const u8 = if (is_last) "  \xe2\x94\x94\xe2\x94\x80 " else "  \xe2\x94\x9c\xe2\x94\x80 ";

            // Column 1: path, min width 35.
            try writer.writeAll(branch);
            try writer.writeAll(path);
            if (path.len < 35) {
                var pad = 35 - path.len;
                while (pad > 0) : (pad -= 1) try writer.writeAll(" ");
            }
            try writer.writeAll(" ");

            // Column 2: [layer]
            try writer.print("[{s}]", .{layer});
            // Pad layer tag to width 10 (longest "[library]" = 9, plus one space).
            var lpad: usize = if (layer.len + 2 < 10) 10 - (layer.len + 2) else 1;
            while (lpad > 0) : (lpad -= 1) try writer.writeAll(" ");

            // Column 3: source (for project/agent), relative to project_root.
            if (!std.mem.eql(u8, layer, "library")) {
                const source_v = f.get("source") orelse {
                    try writer.writeAll("\n");
                    continue;
                };
                if (source_v != .string) {
                    try writer.writeAll("\n");
                    continue;
                }
                const src_abs = source_v.string;
                const src_rel = relativizeToRoot(src_abs, project_root);
                try writer.writeAll(src_rel);
            }
            try writer.writeAll("\n");
        }

        if (cap_i + 1 < caps.items.len) try writer.writeAll("\n");
    }

    try writer.print(
        "\nFiles by layer: {d} library, {d} project, {d} agent\n",
        .{ total_library, total_project, total_agent },
    );
    return .ok;
}

/// Return `abs` with the `project_root/` prefix stripped (if present).
/// Otherwise returns `abs` unchanged.
fn relativizeToRoot(abs: []const u8, project_root: []const u8) []const u8 {
    if (std.mem.startsWith(u8, abs, project_root)) {
        const rest = abs[project_root.len..];
        // Strip a single leading path separator if present.
        if (rest.len > 0 and (rest[0] == '/' or rest[0] == std.fs.path.sep)) {
            return rest[1..];
        }
        return rest;
    }
    return abs;
}
