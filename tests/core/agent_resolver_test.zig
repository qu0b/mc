const std = @import("std");
const diag = @import("diagnostic");
const agent_schema = @import("agent");
const toolset_schema = @import("toolset");
const resolver = @import("agent_resolver");

// ------------------------------------------------------------------
// Fixture helpers
// ------------------------------------------------------------------

const Fixture = struct {
    tmp: std.testing.TmpDir,
    /// Absolute path to the tmp dir (owned; freed in `deinit`).
    root: []u8,

    pub fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        self.tmp.cleanup();
    }

    pub fn join(self: Fixture, allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.root, rel });
    }
};

fn makeFixture(allocator: std.mem.Allocator) !Fixture {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    return .{ .tmp = tmp, .root = root };
}

fn writeFile(tmp: *std.testing.TmpDir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try tmp.dir.makePath(d);
    try tmp.dir.writeFile(.{ .sub_path = path, .data = contents });
}

const VALID_AGENT_JSON =
    \\{
    \\  "name": "foo",
    \\  "description": "Foo agent",
    \\  "model": "claude",
    \\  "provider": "anthropic",
    \\  "thinking": "off",
    \\  "prompt": "./prompt.md",
    \\  "capabilities": {
    \\    "skills": ["cap-a"],
    \\    "commands": [],
    \\    "extensions": ["cap-b"],
    \\    "toolset": "read-only"
    \\  },
    \\  "env": { "required": [], "optional": [] }
    \\}
;

const TOOLSETS_JSON =
    \\{
    \\  "toolsets": {
    \\    "read-only": { "tools": ["Read"], "includes": [] },
    \\    "edit":      { "tools": ["Edit"], "includes": ["read-only"] }
    \\  }
    \\}
;

// Set up a standard valid fixture:
//   .mc/mc.json
//   .mc/plugins/cap-a/
//   .mc/plugins/cap-b/
//   agents/foo/agent.json
//   agents/foo/prompt.md
//   toolsets.json
fn standardFixture(allocator: std.mem.Allocator, agent_json: []const u8) !Fixture {
    var fix = try makeFixture(allocator);
    errdefer fix.deinit(allocator);
    try writeFile(&fix.tmp, ".mc/mc.json", "{\"name\":\"t\"}");
    try fix.tmp.dir.makePath(".mc/plugins/cap-a");
    try fix.tmp.dir.makePath(".mc/plugins/cap-b");
    try writeFile(&fix.tmp, "agents/foo/agent.json", agent_json);
    try writeFile(&fix.tmp, "agents/foo/prompt.md", "");
    try writeFile(&fix.tmp, "toolsets.json", TOOLSETS_JSON);
    return fix;
}

fn pathCount(diags: *const diag.Diagnostics, path: []const u8) usize {
    var n: usize = 0;
    for (diags.items.items) |it| {
        if (std.mem.eql(u8, it.path, path)) n += 1;
    }
    return n;
}

fn errCount(diags: *const diag.Diagnostics) usize {
    var n: usize = 0;
    for (diags.items.items) |it| if (it.severity == .err) {
        n += 1;
    };
    return n;
}

fn warnCount(diags: *const diag.Diagnostics) usize {
    var n: usize = 0;
    for (diags.items.items) |it| if (it.severity == .warn) {
        n += 1;
    };
    return n;
}

// ------------------------------------------------------------------
// Low-level `validate()` tests (no filesystem for toolsets.json, manual ctx)
// ------------------------------------------------------------------

test "validate: all refs valid returns true with no errors" {
    const ally = std.testing.allocator;
    var fix = try standardFixture(ally, VALID_AGENT_JSON);
    defer fix.deinit(ally);

    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = (try agent_schema.parseAgent(
        arena.allocator(),
        "agent.json",
        VALID_AGENT_JSON,
        &d,
    )).?;

    var reg = (try toolset_schema.parseToolsets(
        arena.allocator(),
        "toolsets.json",
        TOOLSETS_JSON,
        &d,
    )).?;
    defer reg.deinit();

    const agent_dir = try fix.join(ally, "agents/foo");
    defer ally.free(agent_dir);

    const ctx = resolver.ResolveContext{
        .project_root = fix.root,
        .agent_dir = agent_dir,
        .installed_capabilities = &.{ "cap-a", "cap-b" },
        .toolsets = &reg,
    };
    const ok = try resolver.validate(ally, agent, "agent.json", ctx, &d);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), errCount(&d));
}

test "validate: skills references unknown capability" {
    const ally = std.testing.allocator;
    var fix = try standardFixture(ally, VALID_AGENT_JSON);
    defer fix.deinit(ally);

    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = (try agent_schema.parseAgent(
        arena.allocator(),
        "agent.json",
        VALID_AGENT_JSON,
        &d,
    )).?;
    var reg = (try toolset_schema.parseToolsets(
        arena.allocator(),
        "toolsets.json",
        TOOLSETS_JSON,
        &d,
    )).?;
    defer reg.deinit();

    const agent_dir = try fix.join(ally, "agents/foo");
    defer ally.free(agent_dir);

    // cap-a is not installed here.
    const ctx = resolver.ResolveContext{
        .project_root = fix.root,
        .agent_dir = agent_dir,
        .installed_capabilities = &.{"cap-b"},
        .toolsets = &reg,
    };
    const ok = try resolver.validate(ally, agent, "agent.json", ctx, &d);
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "capabilities.skills[0]"));
}

test "validate: unknown toolset emits error at capabilities.toolset" {
    const ally = std.testing.allocator;
    var fix = try standardFixture(ally, VALID_AGENT_JSON);
    defer fix.deinit(ally);

    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = (try agent_schema.parseAgent(
        arena.allocator(),
        "agent.json",
        VALID_AGENT_JSON,
        &d,
    )).?;

    // Registry with no "read-only".
    const other =
        \\{ "toolsets": { "edit": { "tools": ["Edit"], "includes": [] } } }
    ;
    var reg = (try toolset_schema.parseToolsets(arena.allocator(), "toolsets.json", other, &d)).?;
    defer reg.deinit();

    const agent_dir = try fix.join(ally, "agents/foo");
    defer ally.free(agent_dir);

    const ctx = resolver.ResolveContext{
        .project_root = fix.root,
        .agent_dir = agent_dir,
        .installed_capabilities = &.{ "cap-a", "cap-b" },
        .toolsets = &reg,
    };
    const ok = try resolver.validate(ally, agent, "agent.json", ctx, &d);
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "capabilities.toolset"));
}

test "validate: missing prompt.md emits error at prompt" {
    const ally = std.testing.allocator;
    var fix = try standardFixture(ally, VALID_AGENT_JSON);
    defer fix.deinit(ally);
    // Remove the prompt.md we wrote in standardFixture.
    try fix.tmp.dir.deleteFile("agents/foo/prompt.md");

    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = (try agent_schema.parseAgent(
        arena.allocator(),
        "agent.json",
        VALID_AGENT_JSON,
        &d,
    )).?;
    var reg = (try toolset_schema.parseToolsets(
        arena.allocator(),
        "toolsets.json",
        TOOLSETS_JSON,
        &d,
    )).?;
    defer reg.deinit();

    const agent_dir = try fix.join(ally, "agents/foo");
    defer ally.free(agent_dir);

    const ctx = resolver.ResolveContext{
        .project_root = fix.root,
        .agent_dir = agent_dir,
        .installed_capabilities = &.{ "cap-a", "cap-b" },
        .toolsets = &reg,
    };
    const ok = try resolver.validate(ally, agent, "agent.json", ctx, &d);
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "prompt"));
}

test "validate: multiple violations accumulate (skills + toolset + prompt)" {
    const ally = std.testing.allocator;
    // skills includes an unknown capability at index 2.
    const src =
        \\{
        \\  "name": "foo",
        \\  "description": "Foo agent",
        \\  "model": "claude",
        \\  "provider": "anthropic",
        \\  "thinking": "off",
        \\  "prompt": "./prompt.md",
        \\  "capabilities": {
        \\    "skills": ["cap-a", "cap-b", "does-not-exist"],
        \\    "commands": [],
        \\    "extensions": [],
        \\    "toolset": "no-such-toolset"
        \\  },
        \\  "env": { "required": [], "optional": [] }
        \\}
    ;
    var fix = try standardFixture(ally, src);
    defer fix.deinit(ally);
    try fix.tmp.dir.deleteFile("agents/foo/prompt.md");

    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = (try agent_schema.parseAgent(arena.allocator(), "agent.json", src, &d)).?;
    var reg = (try toolset_schema.parseToolsets(
        arena.allocator(),
        "toolsets.json",
        TOOLSETS_JSON,
        &d,
    )).?;
    defer reg.deinit();

    const agent_dir = try fix.join(ally, "agents/foo");
    defer ally.free(agent_dir);

    const ctx = resolver.ResolveContext{
        .project_root = fix.root,
        .agent_dir = agent_dir,
        .installed_capabilities = &.{ "cap-a", "cap-b" },
        .toolsets = &reg,
    };
    const ok = try resolver.validate(ally, agent, "agent.json", ctx, &d);
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "capabilities.skills[2]"));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "capabilities.toolset"));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "prompt"));
    try std.testing.expectEqual(@as(usize, 3), errCount(&d));
}

test "validate: commands entries emit warnings, not errors" {
    const ally = std.testing.allocator;
    const src =
        \\{
        \\  "name": "foo",
        \\  "description": "Foo agent",
        \\  "model": "claude",
        \\  "provider": "anthropic",
        \\  "thinking": "off",
        \\  "prompt": "./prompt.md",
        \\  "capabilities": {
        \\    "skills": [],
        \\    "commands": ["/build", "/test"],
        \\    "extensions": [],
        \\    "toolset": "read-only"
        \\  },
        \\  "env": { "required": [], "optional": [] }
        \\}
    ;
    var fix = try standardFixture(ally, src);
    defer fix.deinit(ally);

    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();
    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = (try agent_schema.parseAgent(arena.allocator(), "agent.json", src, &d)).?;
    var reg = (try toolset_schema.parseToolsets(
        arena.allocator(),
        "toolsets.json",
        TOOLSETS_JSON,
        &d,
    )).?;
    defer reg.deinit();

    const agent_dir = try fix.join(ally, "agents/foo");
    defer ally.free(agent_dir);

    const ctx = resolver.ResolveContext{
        .project_root = fix.root,
        .agent_dir = agent_dir,
        .installed_capabilities = &.{ "cap-a", "cap-b" },
        .toolsets = &reg,
    };
    const ok = try resolver.validate(ally, agent, "agent.json", ctx, &d);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), errCount(&d));
    // One warning per command.
    try std.testing.expectEqual(@as(usize, 2), warnCount(&d));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "capabilities.commands[0]"));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "capabilities.commands[1]"));
}

// ------------------------------------------------------------------
// validateAgentInProject tests (exercise the filesystem walking)
// ------------------------------------------------------------------

test "validateAgentInProject: end-to-end valid project" {
    const ally = std.testing.allocator;
    var fix = try standardFixture(ally, VALID_AGENT_JSON);
    defer fix.deinit(ally);

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const ok = try resolver.validateAgentInProject(ally, fix.root, "foo", &d);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), errCount(&d));
}

test "validateAgentInProject: missing agent dir returns false" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);
    try writeFile(&fix.tmp, ".mc/mc.json", "{\"name\":\"t\"}");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const ok = try resolver.validateAgentInProject(ally, fix.root, "ghost", &d);
    try std.testing.expect(!ok);
    try std.testing.expect(errCount(&d) >= 1);
}

test "validateAgentInProject: not a sandbox returns false" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const ok = try resolver.validateAgentInProject(ally, fix.root, "foo", &d);
    try std.testing.expect(!ok);
    try std.testing.expect(errCount(&d) >= 1);
}

test "validateAgentInProject: no toolsets.json anywhere yields warning, continues" {
    const ally = std.testing.allocator;
    var fix = try standardFixture(ally, VALID_AGENT_JSON);
    defer fix.deinit(ally);
    try fix.tmp.dir.deleteFile("toolsets.json");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const ok = try resolver.validateAgentInProject(ally, fix.root, "foo", &d);
    // No toolset errors — toolset check was skipped with a warning.
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), errCount(&d));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "capabilities.toolset"));
    // And the single diagnostic on that path is a warning.
    var saw_warn: bool = false;
    for (d.items.items) |it| {
        if (std.mem.eql(u8, it.path, "capabilities.toolset") and it.severity == .warn) saw_warn = true;
    }
    try std.testing.expect(saw_warn);
}
