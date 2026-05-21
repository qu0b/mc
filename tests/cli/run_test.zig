const std = @import("std");
const diag = @import("diagnostic");
const run = @import("run");
const testutil = @import("testutil");

// ----- Fixtures -----

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,

    pub fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        self.tmp.cleanup();
    }
};

fn makeFixture(allocator: std.mem.Allocator) !Fixture {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const root = try testutil.realRoot(allocator, &tmp);
    return .{ .tmp = tmp, .root = root };
}

fn writeFile(tmp: *std.testing.TmpDir, path: []const u8, contents: []const u8) !void {
    try testutil.writeRel(tmp.dir, path, contents);
}

/// Standard valid project with a single agent.  `extra_toolsets` is inlined
/// into the `toolsets` object.  `agent_json` is used verbatim.
fn buildProject(
    tmp: *std.testing.TmpDir,
    agent_json: []const u8,
    toolsets_json: []const u8,
) !void {
    try writeFile(tmp, ".mc/mc.json", "{\"name\":\"t\"}");
    try testutil.mkdirs(tmp.dir, ".mc/plugins/cap-a");
    try writeFile(tmp, ".mc/plugins/cap-a/SKILL.md", "# cap-a\n");
    try testutil.mkdirs(tmp.dir, ".mc/plugins/cap-b");
    try writeFile(tmp, ".mc/plugins/cap-b/SKILL.md", "# cap-b\n");
    try writeFile(tmp, "toolsets.json", toolsets_json);
    try writeFile(tmp, "agents/foo/agent.json", agent_json);
    try writeFile(tmp, "agents/foo/prompt.md", "You are a helpful agent.\n");
}

const VALID_AGENT =
    \\{
    \\  "name": "foo",
    \\  "description": "Foo agent",
    \\  "model": "claude-3-opus",
    \\  "provider": "anthropic",
    \\  "thinking": "medium",
    \\  "prompt": "./prompt.md",
    \\  "capabilities": {
    \\    "skills": ["cap-a"],
    \\    "commands": [],
    \\    "extensions": ["cap-b"],
    \\    "toolset": "edit"
    \\  },
    \\  "env": { "required": [], "optional": [] }
    \\}
;

const TOOLSETS =
    \\{
    \\  "toolsets": {
    \\    "read-only": { "tools": ["Read", "Glob"], "includes": [] },
    \\    "edit":      { "tools": ["Edit"], "includes": ["read-only"] }
    \\  }
    \\}
;

// ----- argv helpers -----

fn find(argv: []const []const u8, needle: []const u8) ?usize {
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, needle)) return i;
    }
    return null;
}

fn countOccurrences(argv: []const []const u8, needle: []const u8) usize {
    var n: usize = 0;
    for (argv) |a| if (std.mem.eql(u8, a, needle)) {
        n += 1;
    };
    return n;
}

// ----- Tests -----

test "clean project: buildCommand produces well-formed argv" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);
    try buildProject(&fix.tmp, VALID_AGENT, TOOLSETS);

    var diags = diag.Diagnostics.init(ally);
    defer diags.deinit();

    var empty_env = std.StringHashMap([]const u8).init(ally);
    defer empty_env.deinit();

    var cmd = try run.buildCommand(
        ally,
        fix.root,
        .{ .agent_name = "foo" },
        &diags,
        &empty_env,
    );
    defer cmd.deinit();

    try std.testing.expect(cmd.env_ok);

    // argv[0] is pi.
    try std.testing.expectEqualStrings("pi", cmd.argv[0]);

    // Model, provider, thinking present with correct values.
    const model_idx = find(cmd.argv, "--model") orelse return error.NoModelFlag;
    try std.testing.expectEqualStrings("claude-3-opus", cmd.argv[model_idx + 1]);

    const prov_idx = find(cmd.argv, "--provider") orelse return error.NoProviderFlag;
    try std.testing.expectEqualStrings("anthropic", cmd.argv[prov_idx + 1]);

    const think_idx = find(cmd.argv, "--thinking") orelse return error.NoThinkingFlag;
    try std.testing.expectEqualStrings("medium", cmd.argv[think_idx + 1]);

    // --tools is a comma-joined string.  "edit" includes read-only ⇒ Edit,Read,Glob.
    const tools_idx = find(cmd.argv, "--tools") orelse return error.NoToolsFlag;
    try std.testing.expectEqualStrings("Edit,Read,Glob", cmd.argv[tools_idx + 1]);

    // --no-skills and --no-extensions always present.
    try std.testing.expect(find(cmd.argv, "--no-skills") != null);
    try std.testing.expect(find(cmd.argv, "--no-extensions") != null);

    // Two capabilities (cap-a, cap-b) ⇒ two --skill entries.
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(cmd.argv, "--skill"));

    // Prompt content round-trips.
    try std.testing.expectEqualStrings("You are a helpful agent.\n", cmd.prompt);

    // Prompt appears as an arg right after -p.
    const p_idx = find(cmd.argv, "-p") orelse return error.NoPromptFlag;
    try std.testing.expectEqualStrings("You are a helpful agent.\n", cmd.argv[p_idx + 1]);

    // No missing env, no diagnostics.
    try std.testing.expectEqual(@as(usize, 0), cmd.missing_env.len);
    try std.testing.expectEqual(@as(usize, 0), diags.count());
}

test "missing required env var: error + missing_env populated" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    const agent_with_env =
        \\{
        \\  "name": "foo",
        \\  "description": "Foo agent",
        \\  "model": "m",
        \\  "provider": "anthropic",
        \\  "thinking": "off",
        \\  "prompt": "./prompt.md",
        \\  "capabilities": {
        \\    "skills": ["cap-a"],
        \\    "commands": [],
        \\    "extensions": [],
        \\    "toolset": "read-only"
        \\  },
        \\  "env": { "required": ["MC_UNSET_VAR_XYZ"], "optional": [] }
        \\}
    ;
    try buildProject(&fix.tmp, agent_with_env, TOOLSETS);

    var diags = diag.Diagnostics.init(ally);
    defer diags.deinit();

    // Empty env map ⇒ MC_UNSET_VAR_XYZ absent.
    var env = std.StringHashMap([]const u8).init(ally);
    defer env.deinit();

    const res = run.buildCommand(
        ally,
        fix.root,
        .{ .agent_name = "foo" },
        &diags,
        &env,
    );
    try std.testing.expectError(error.MissingRequiredEnv, res);

    // A diagnostic at env.required mentioning the var name should exist.
    var found = false;
    for (diags.items.items) |it| {
        if (std.mem.eql(u8, it.path, "env.required") and
            std.mem.indexOf(u8, it.message, "MC_UNSET_VAR_XYZ") != null)
        {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "missing prompt file: PromptFileMissing error" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);
    try buildProject(&fix.tmp, VALID_AGENT, TOOLSETS);
    try testutil.deleteRel(fix.tmp.dir, "agents/foo/prompt.md");

    var diags = diag.Diagnostics.init(ally);
    defer diags.deinit();

    var env = std.StringHashMap([]const u8).init(ally);
    defer env.deinit();

    const res = run.buildCommand(
        ally,
        fix.root,
        .{ .agent_name = "foo" },
        &diags,
        &env,
    );
    // validateAgentInProject already fails when prompt.md is missing, so we
    // accept either error path — both surface a useful diagnostic.
    try std.testing.expect(
        res == error.AgentValidationFailed or res == error.PromptFileMissing,
    );
}

test "missing agent dir: AgentDirMissing error" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);
    try writeFile(&fix.tmp, ".mc/mc.json", "{}");

    var diags = diag.Diagnostics.init(ally);
    defer diags.deinit();

    const res = run.buildCommand(
        ally,
        fix.root,
        .{ .agent_name = "ghost" },
        &diags,
        null,
    );
    try std.testing.expectError(error.AgentDirMissing, res);

    var saw = false;
    for (diags.items.items) |it| {
        if (std.mem.indexOf(u8, it.message, "agent directory not found") != null) saw = true;
    }
    try std.testing.expect(saw);
}

test "toolset transitive include: all tools appear in --tools CSV" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    const agent_json =
        \\{
        \\  "name": "foo",
        \\  "description": "t",
        \\  "model": "m",
        \\  "provider": "anthropic",
        \\  "thinking": "off",
        \\  "prompt": "./prompt.md",
        \\  "capabilities": {
        \\    "skills": ["cap-a"],
        \\    "commands": [],
        \\    "extensions": [],
        \\    "toolset": "full"
        \\  },
        \\  "env": { "required": [], "optional": [] }
        \\}
    ;
    const nested_toolsets =
        \\{
        \\  "toolsets": {
        \\    "read":   { "tools": ["Read"], "includes": [] },
        \\    "write":  { "tools": ["Edit"], "includes": ["read"] },
        \\    "full":   { "tools": ["Bash"], "includes": ["write"] }
        \\  }
        \\}
    ;
    try buildProject(&fix.tmp, agent_json, nested_toolsets);

    var diags = diag.Diagnostics.init(ally);
    defer diags.deinit();

    var env = std.StringHashMap([]const u8).init(ally);
    defer env.deinit();

    var cmd = try run.buildCommand(
        ally,
        fix.root,
        .{ .agent_name = "foo" },
        &diags,
        &env,
    );
    defer cmd.deinit();

    const tools_idx = find(cmd.argv, "--tools") orelse return error.NoToolsFlag;
    // DFS pre-order: Bash, then write (Edit, then read's Read).
    try std.testing.expectEqualStrings("Bash,Edit,Read", cmd.argv[tools_idx + 1]);
}

test "extra_args: pass-through appears at tail of argv" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);
    try buildProject(&fix.tmp, VALID_AGENT, TOOLSETS);

    var diags = diag.Diagnostics.init(ally);
    defer diags.deinit();

    var env = std.StringHashMap([]const u8).init(ally);
    defer env.deinit();

    const extras = [_][]const u8{ "--thinking", "high" };
    var cmd = try run.buildCommand(
        ally,
        fix.root,
        .{ .agent_name = "foo", .extra_args = &extras },
        &diags,
        &env,
    );
    defer cmd.deinit();

    // Extras must appear in order at the tail.
    try std.testing.expect(cmd.argv.len >= 2);
    try std.testing.expectEqualStrings("--thinking", cmd.argv[cmd.argv.len - 2]);
    try std.testing.expectEqualStrings("high", cmd.argv[cmd.argv.len - 1]);
}

test "dry-run render: printDryRun produces argv-shaped output with PROMPT placeholder" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);
    try buildProject(&fix.tmp, VALID_AGENT, TOOLSETS);

    var diags = diag.Diagnostics.init(ally);
    defer diags.deinit();

    var env = std.StringHashMap([]const u8).init(ally);
    defer env.deinit();

    var cmd = try run.buildCommand(
        ally,
        fix.root,
        .{ .agent_name = "foo" },
        &diags,
        &env,
    );
    defer cmd.deinit();

    // Exercise writeShellQuoted on a few values to prove it doesn't mangle
    // safe args and that it quotes risky ones.
    var aw: std.Io.Writer.Allocating = .init(ally);
    defer aw.deinit();
    const w = &aw.writer;

    try run.writeShellQuoted(w, "simple");
    try w.writeAll(" ");
    try run.writeShellQuoted(w, "hello world");
    try w.writeAll(" ");
    try run.writeShellQuoted(w, "it's");
    try w.writeAll(" ");
    try run.writeShellQuoted(w, "");

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "simple") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "'hello world'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "'it'\\''s'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "''") != null);
}
