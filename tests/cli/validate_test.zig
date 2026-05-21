const std = @import("std");
const diag = @import("diagnostic");
const validate = @import("validate");
const testutil = @import("testutil");

// ------------------------------------------------------------------
// Fixture scaffolding
// ------------------------------------------------------------------

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

// ------------------------------------------------------------------
// Canonical valid fragments
// ------------------------------------------------------------------

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
    \\    "extensions": [],
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

const VALID_PLUGIN_JSON =
    \\{
    \\  "name": "cap-a",
    \\  "version": "1.0.0",
    \\  "description": "Test cap"
    \\}
;

fn cleanProjectFixture(allocator: std.mem.Allocator) !Fixture {
    var fix = try makeFixture(allocator);
    errdefer fix.deinit(allocator);
    try writeFile(&fix.tmp, ".mc/mc.json", "{\"name\":\"t\"}");
    try testutil.mkdirs(fix.tmp.dir, ".mc/plugins/cap-a");
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/plugin.json", VALID_PLUGIN_JSON);
    try writeFile(&fix.tmp, "toolsets.json", TOOLSETS_JSON);
    try writeFile(&fix.tmp, "agents/foo/agent.json", VALID_AGENT_JSON);
    try writeFile(&fix.tmp, "agents/foo/prompt.md", "prompt");
    return fix;
}

// ------------------------------------------------------------------
// Diagnostic counters
// ------------------------------------------------------------------

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

fn countInFile(diags: *const diag.Diagnostics, file_sub: []const u8, sev: diag.Severity) usize {
    var n: usize = 0;
    for (diags.items.items) |it| {
        if (it.severity != sev) continue;
        if (std.mem.indexOf(u8, it.file, file_sub) != null) n += 1;
    }
    return n;
}

// ==================================================================
// Tests
// ==================================================================

test "validate: clean project — 0 errors" {
    const ally = std.testing.allocator;
    var fix = try cleanProjectFixture(ally);
    defer fix.deinit(ally);

    var result = try validate.runAt(ally, fix.root);
    defer result.deinit();

    try std.testing.expect(result.is_sandbox);
    try std.testing.expect(!result.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), errCount(&result.diags));
}

test "validate: agent with unknown toolset — 1 error" {
    const ally = std.testing.allocator;
    var fix = try cleanProjectFixture(ally);
    defer fix.deinit(ally);

    const bad_agent =
        \\{
        \\  "name": "foo",
        \\  "description": "Foo",
        \\  "model": "claude",
        \\  "provider": "anthropic",
        \\  "thinking": "off",
        \\  "prompt": "./prompt.md",
        \\  "capabilities": {
        \\    "skills": ["cap-a"],
        \\    "commands": [],
        \\    "extensions": [],
        \\    "toolset": "no-such-toolset"
        \\  },
        \\  "env": { "required": [], "optional": [] }
        \\}
    ;
    try writeFile(&fix.tmp, "agents/foo/agent.json", bad_agent);

    var result = try validate.runAt(ally, fix.root);
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), errCount(&result.diags));
    // The error lives on the agent file.
    try std.testing.expectEqual(
        @as(usize, 1),
        countInFile(&result.diags, "agents/foo/agent.json", .err),
    );
}

test "validate: plugin with bad compat range — 1 error" {
    const ally = std.testing.allocator;
    var fix = try cleanProjectFixture(ally);
    defer fix.deinit(ally);

    const bad_plugin =
        \\{
        \\  "name": "cap-a",
        \\  "version": "1.0.0",
        \\  "compat": { "pluginApi": "not-a-range" }
        \\}
    ;
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/plugin.json", bad_plugin);

    var result = try validate.runAt(ally, fix.root);
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    // One diagnostic at the plugin.json for the invalid range.
    try std.testing.expect(countInFile(&result.diags, "cap-a/plugin.json", .err) >= 1);
}

test "validate: toolsets.json with cycle — cycle diagnostic emitted" {
    const ally = std.testing.allocator;
    var fix = try cleanProjectFixture(ally);
    defer fix.deinit(ally);

    const cyclic =
        \\{
        \\  "toolsets": {
        \\    "read-only": { "tools": ["Read"], "includes": ["edit"] },
        \\    "edit":      { "tools": ["Edit"], "includes": ["read-only"] }
        \\  }
        \\}
    ;
    try writeFile(&fix.tmp, "toolsets.json", cyclic);

    var result = try validate.runAt(ally, fix.root);
    defer result.deinit();

    try std.testing.expect(result.hasErrors());

    var saw_cycle = false;
    for (result.diags.items.items) |it| {
        if (std.mem.indexOf(u8, it.message, "cyclic includes") != null) saw_cycle = true;
    }
    try std.testing.expect(saw_cycle);
}

test "validate: plugin with unsatisfiable minMcVersion — 1 error" {
    const ally = std.testing.allocator;
    var fix = try cleanProjectFixture(ally);
    defer fix.deinit(ally);

    // mc version baked in is 0.1.0 — asking for >=99.0.0 must fail.
    const bad_plugin =
        \\{
        \\  "name": "cap-a",
        \\  "version": "1.0.0",
        \\  "compat": { "minMcVersion": ">=99.0.0" }
        \\}
    ;
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/plugin.json", bad_plugin);

    var result = try validate.runAt(ally, fix.root);
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    // At least one error on the plugin — compat check ran.
    var saw_compat_err = false;
    for (result.diags.items.items) |it| {
        if (it.severity != .err) continue;
        if (std.mem.indexOf(u8, it.path, "compat.minMcVersion") != null) saw_compat_err = true;
    }
    try std.testing.expect(saw_compat_err);
}

test "validate: agent with missing prompt.md — 1 error" {
    const ally = std.testing.allocator;
    var fix = try cleanProjectFixture(ally);
    defer fix.deinit(ally);
    try testutil.deleteRel(fix.tmp.dir, "agents/foo/prompt.md");

    var result = try validate.runAt(ally, fix.root);
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    var saw_prompt = false;
    for (result.diags.items.items) |it| {
        if (std.mem.eql(u8, it.path, "prompt") and it.severity == .err) saw_prompt = true;
    }
    try std.testing.expect(saw_prompt);
}

test "validate: multiple independent errors across files — all captured" {
    const ally = std.testing.allocator;
    var fix = try cleanProjectFixture(ally);
    defer fix.deinit(ally);

    // Break plugin (invalid pluginApi range).
    try writeFile(
        &fix.tmp,
        ".mc/plugins/cap-a/plugin.json",
        \\{ "name": "cap-a", "compat": { "pluginApi": "xxxxx" } }
    );
    // Break agent (missing prompt.md).
    try testutil.deleteRel(fix.tmp.dir, "agents/foo/prompt.md");
    // Break toolsets (cycle).
    try writeFile(
        &fix.tmp,
        "toolsets.json",
        \\{
        \\  "toolsets": {
        \\    "read-only": { "tools": ["Read"], "includes": ["edit"] },
        \\    "edit":      { "tools": ["Edit"], "includes": ["read-only"] }
        \\  }
        \\}
    );

    var result = try validate.runAt(ally, fix.root);
    defer result.deinit();

    try std.testing.expect(result.hasErrors());
    // At least 3 errors collected in a single pass
    // (plugin pluginApi, agent prompt, toolset cycle).
    try std.testing.expect(errCount(&result.diags) >= 3);
}

test "validate: no toolsets.json — warning, not error" {
    const ally = std.testing.allocator;
    var fix = try cleanProjectFixture(ally);
    defer fix.deinit(ally);
    try testutil.deleteRel(fix.tmp.dir, "toolsets.json");

    var result = try validate.runAt(ally, fix.root);
    defer result.deinit();

    try std.testing.expect(!result.hasErrors());
    // One warning from validate for missing registry, one per agent for
    // unverifiable toolset ref = at least 2 warnings, 0 errors.
    try std.testing.expectEqual(@as(usize, 0), errCount(&result.diags));
    try std.testing.expect(warnCount(&result.diags) >= 2);
}

test "validate: no agents dir — runs clean" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);
    try writeFile(&fix.tmp, ".mc/mc.json", "{\"name\":\"t\"}");
    // Intentionally no agents/ dir, no plugins, no toolsets.

    var result = try validate.runAt(ally, fix.root);
    defer result.deinit();

    try std.testing.expect(result.is_sandbox);
    try std.testing.expectEqual(@as(usize, 0), errCount(&result.diags));
}

test "validate: not a sandbox — graceful, no diagnostics" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);
    // No .mc/mc.json written.

    var result = try validate.runAt(ally, fix.root);
    defer result.deinit();

    try std.testing.expect(!result.is_sandbox);
    try std.testing.expectEqual(@as(usize, 0), result.diags.count());
}
