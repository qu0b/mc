const std = @import("std");
const diag = @import("diagnostic");
const agent_schema = @import("agent");
const materialize = @import("materialize");
const testutil = @import("testutil");
const iocompat = @import("iocompat");

// ------------------------------------------------------------------
// Fixture helpers
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

fn writeExec(tmp: *std.testing.TmpDir, path: []const u8, contents: []const u8, mode: std.posix.mode_t) !void {
    const io = iocompat.getIo();
    try testutil.writeRel(tmp.dir, path, contents);
    var f = try tmp.dir.openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    try f.setPermissions(io, std.Io.File.Permissions.fromMode(mode));
}

fn readFile(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, path: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(iocompat.getIo(), path, allocator, .unlimited);
}

fn makeAgent(name: []const u8, skills: []const []const u8, extensions: []const []const u8) agent_schema.Agent {
    return .{
        .name = name,
        .description = "t",
        .model = "m",
        .provider = "anthropic",
        .thinking = "off",
        .prompt = "prompt.md",
        .capabilities = .{
            .skills = skills,
            .commands = &.{},
            .extensions = extensions,
            .toolset = "read-only",
        },
        .env = .{ .required = &.{}, .optional = &.{} },
    };
}

fn findTrace(traces: []const materialize.FileTrace, cap: []const u8, rel: []const u8) ?materialize.FileTrace {
    for (traces) |t| {
        if (std.mem.eql(u8, t.capability, cap) and std.mem.eql(u8, t.relative_path, rel)) return t;
    }
    return null;
}

fn countTracesFor(traces: []const materialize.FileTrace, cap: []const u8, rel: []const u8) usize {
    var n: usize = 0;
    for (traces) |t| {
        if (std.mem.eql(u8, t.capability, cap) and std.mem.eql(u8, t.relative_path, rel)) n += 1;
    }
    return n;
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

test "library-only capability: all files come from library layer" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeFile(&fix.tmp, ".mc/plugins/cap-b/SKILL.md", "lib-skill");
    try writeFile(&fix.tmp, ".mc/plugins/cap-b/scripts/run.sh", "echo lib");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-b"}, &.{});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.traces.len);
    for (result.traces) |t| try std.testing.expectEqual(materialize.Layer.library, t.layer);

    // Verify files exist at runtime dir.
    const skill_abs = try std.fs.path.join(ally, &.{ result.runtime_dir, "cap-b", "SKILL.md" });
    defer ally.free(skill_abs);
    try iocompat.accessAbsolute(skill_abs);
}

test "agent override wins over project and library" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/SKILL.md", "LIB");
    try writeFile(&fix.tmp, "overrides/cap-a/SKILL.md", "PROJ");
    try writeFile(&fix.tmp, "agents/foo/overrides/cap-a/SKILL.md", "AGENT");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-a"}, &.{});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    const t = findTrace(result.traces, "cap-a", "SKILL.md") orelse return error.TraceMissing;
    try std.testing.expectEqual(materialize.Layer.agent, t.layer);

    const abs = try std.fs.path.join(ally, &.{ result.runtime_dir, "cap-a", "SKILL.md" });
    defer ally.free(abs);
    const contents = try iocompat.readFile(ally, abs);
    defer ally.free(contents);
    try std.testing.expectEqualStrings("AGENT", contents);
}

test "project override wins over library when no agent override" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/scripts/start.sh", "LIB");
    try writeFile(&fix.tmp, "overrides/cap-a/scripts/start.sh", "PROJ");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-a"}, &.{});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    const t = findTrace(result.traces, "cap-a", "scripts/start.sh") orelse return error.TraceMissing;
    try std.testing.expectEqual(materialize.Layer.project, t.layer);

    const abs = try std.fs.path.join(ally, &.{ result.runtime_dir, "cap-a", "scripts/start.sh" });
    defer ally.free(abs);
    const contents = try iocompat.readFile(ally, abs);
    defer ally.free(contents);
    try std.testing.expectEqualStrings("PROJ", contents);
}

test "library-only file traces as .library" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/SKILL.md", "LIB");
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/scripts/eval.sh", "LIB-EVAL");
    // overrides only touch one file; another is library-only.
    try writeFile(&fix.tmp, "agents/foo/overrides/cap-a/SKILL.md", "AGENT");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-a"}, &.{});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    const t = findTrace(result.traces, "cap-a", "scripts/eval.sh") orelse return error.TraceMissing;
    try std.testing.expectEqual(materialize.Layer.library, t.layer);
}

test "additive project file: not in library, added from project" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/SKILL.md", "LIB");
    try writeFile(&fix.tmp, "overrides/cap-a/NOTES.md", "proj-notes");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-a"}, &.{});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    const t = findTrace(result.traces, "cap-a", "NOTES.md") orelse return error.TraceMissing;
    try std.testing.expectEqual(materialize.Layer.project, t.layer);

    const abs = try std.fs.path.join(ally, &.{ result.runtime_dir, "cap-a", "NOTES.md" });
    defer ally.free(abs);
    try iocompat.accessAbsolute(abs);
}

test "additive agent file: not in library or project, added from agent" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/SKILL.md", "LIB");
    try writeFile(&fix.tmp, "agents/foo/overrides/cap-a/extra.sh", "#!/bin/sh\nexit 0\n");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-a"}, &.{});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    const t = findTrace(result.traces, "cap-a", "extra.sh") orelse return error.TraceMissing;
    try std.testing.expectEqual(materialize.Layer.agent, t.layer);
}

test "missing capability: diagnostic emitted, error returned, no dir created" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-nonexistent"}, &.{});

    const result = materialize.materializeAgent(ally, fix.root, agent, &d);
    try std.testing.expectError(error.LibraryCapabilityMissing, result);

    // A diagnostic mentioning the capability name should exist.
    var found = false;
    for (d.items.items) |it| {
        if (std.mem.indexOf(u8, it.message, "cap-nonexistent") != null) found = true;
    }
    try std.testing.expect(found);

    // Capability runtime dir should NOT exist.
    const cap_dir = try std.fs.path.join(ally, &.{ fix.root, ".mc", "runtime", "foo", "cap-nonexistent" });
    defer ally.free(cap_dir);
    const res = iocompat.accessAbsolute(cap_dir);
    try std.testing.expectError(error.FileNotFound, res);
}

test "trace.json format: parseable and well-formed" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeFile(
        &fix.tmp,
        ".mc/plugins/cap-a/plugin.json",
        \\{ "name": "cap-a", "version": "1.2.3" }
        ,
    );
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/SKILL.md", "LIB");
    try writeFile(&fix.tmp, "agents/foo/overrides/cap-a/SKILL.md", "AGENT");
    try writeFile(&fix.tmp, "overrides/cap-a/NOTES.md", "proj-notes");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-a"}, &.{});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    try materialize.writeTrace(result, ally);

    const trace_abs = try std.fs.path.join(ally, &.{ result.runtime_dir, "trace.json" });
    defer ally.free(trace_abs);
    const src = try iocompat.readFile(ally, trace_abs);
    defer ally.free(src);

    var parsed = try std.json.parseFromSlice(std.json.Value, ally, src, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("foo", root.get("agent").?.string);
    try std.testing.expect(root.get("generated_at").?.string.len >= 20);

    const caps = root.get("capabilities").?.array;
    try std.testing.expectEqual(@as(usize, 1), caps.items.len);
    const cap0 = caps.items[0].object;
    try std.testing.expectEqualStrings("cap-a", cap0.get("name").?.string);
    try std.testing.expectEqualStrings("1.2.3", cap0.get("library_version").?.string);

    const files = cap0.get("files").?.array;
    // NOTES.md (project-additive), SKILL.md (agent), plugin.json (library).
    try std.testing.expectEqual(@as(usize, 3), files.items.len);
    // Sorted alphabetically: NOTES.md, SKILL.md, plugin.json.
    try std.testing.expectEqualStrings("NOTES.md", files.items[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("project", files.items[0].object.get("layer").?.string);
    try std.testing.expectEqualStrings("SKILL.md", files.items[1].object.get("path").?.string);
    try std.testing.expectEqualStrings("agent", files.items[1].object.get("layer").?.string);
    try std.testing.expectEqualStrings("plugin.json", files.items[2].object.get("path").?.string);
    try std.testing.expectEqualStrings("library", files.items[2].object.get("layer").?.string);
}

test "executable bit preserved when copying" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeExec(&fix.tmp, ".mc/plugins/cap-a/SKILL.md", "x", 0o644);
    try writeExec(&fix.tmp, ".mc/plugins/cap-a/scripts/run.sh", "#!/bin/sh\n", 0o755);

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-a"}, &.{});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    const run_abs = try std.fs.path.join(ally, &.{ result.runtime_dir, "cap-a", "scripts/run.sh" });
    defer ally.free(run_abs);
    var f = try iocompat.openFileAbsolute(run_abs);
    defer f.close(iocompat.getIo());
    const st = try f.stat(iocompat.getIo());
    // Check the owner-execute bit is set.
    try std.testing.expect((st.permissions.toMode() & 0o100) != 0);
}

test "subdirectory walk preserves relative path" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/scripts/nested/deep.sh", "deep");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-a"}, &.{});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    const t = findTrace(result.traces, "cap-a", "scripts/nested/deep.sh") orelse return error.TraceMissing;
    try std.testing.expectEqual(materialize.Layer.library, t.layer);

    const abs = try std.fs.path.join(ally, &.{ result.runtime_dir, "cap-a", "scripts/nested/deep.sh" });
    defer ally.free(abs);
    try iocompat.accessAbsolute(abs);
}

test "multiple capabilities each materialized into its own dir" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/SKILL.md", "A");
    try writeFile(&fix.tmp, ".mc/plugins/cap-b/SKILL.md", "B");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{ "cap-a", "cap-b" }, &.{});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.traces.len);

    const a_abs = try std.fs.path.join(ally, &.{ result.runtime_dir, "cap-a", "SKILL.md" });
    defer ally.free(a_abs);
    const b_abs = try std.fs.path.join(ally, &.{ result.runtime_dir, "cap-b", "SKILL.md" });
    defer ally.free(b_abs);
    try iocompat.accessAbsolute(a_abs);
    try iocompat.accessAbsolute(b_abs);
}

test "duplicate across skills and extensions: materialized once" {
    const ally = std.testing.allocator;
    var fix = try makeFixture(ally);
    defer fix.deinit(ally);

    try writeFile(&fix.tmp, ".mc/mc.json", "{}");
    try writeFile(&fix.tmp, ".mc/plugins/cap-a/SKILL.md", "A");

    var d = diag.Diagnostics.init(ally);
    defer d.deinit();

    const agent = makeAgent("foo", &.{"cap-a"}, &.{"cap-a"});

    var result = try materialize.materializeAgent(ally, fix.root, agent, &d);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.traces.len);
    try std.testing.expectEqual(@as(usize, 1), countTracesFor(result.traces, "cap-a", "SKILL.md"));
}
