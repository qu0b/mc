const std = @import("std");
const agent = @import("agent");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// ---------------- helpers ----------------

fn initFakeSandbox(dir: std.fs.Dir) !void {
    try dir.makeDir(".mc");
    try dir.writeFile(.{ .sub_path = ".mc/mc.json", .data = "{\"name\":\"test\"}\n" });
}

fn tmpPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    return tmp.dir.realpathAlloc(allocator, ".");
}

fn writeTrace(dir: std.fs.Dir, agent_name: []const u8, body: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const runtime_dir = try std.fmt.bufPrint(&path_buf, ".mc/runtime/{s}", .{agent_name});
    try dir.makePath(runtime_dir);
    var trace_path_buf: [256]u8 = undefined;
    const trace_path = try std.fmt.bufPrint(&trace_path_buf, "{s}/trace.json", .{runtime_dir});
    try dir.writeFile(.{ .sub_path = trace_path, .data = body });
}

// ---------------- 1. trace exists, simple case ----------------

test "executeShowWriter: single cap, 3 files across 3 layers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFakeSandbox(tmp.dir);

    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);

    // Build source paths that start with the project root so relativization hits.
    const agent_source = try std.fmt.allocPrint(
        allocator,
        "{s}/agents/rev/overrides/browser-tools/SKILL.md",
        .{root},
    );
    defer allocator.free(agent_source);
    const project_source = try std.fmt.allocPrint(
        allocator,
        "{s}/overrides/browser-tools/scripts/start.sh",
        .{root},
    );
    defer allocator.free(project_source);
    const library_source = try std.fmt.allocPrint(
        allocator,
        "{s}/.mc/plugins/browser-tools/scripts/eval.sh",
        .{root},
    );
    defer allocator.free(library_source);

    const trace_body = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "agent": "rev",
        \\  "generated_at": "2026-04-11T23:20:00Z",
        \\  "capabilities": [
        \\    {{
        \\      "name": "browser-tools",
        \\      "library_version": "1.0.0",
        \\      "files": [
        \\        {{ "path": "SKILL.md",         "layer": "agent",   "source": "{s}" }},
        \\        {{ "path": "scripts/start.sh", "layer": "project", "source": "{s}" }},
        \\        {{ "path": "scripts/eval.sh",  "layer": "library", "source": "{s}" }}
        \\      ]
        \\    }}
        \\  ]
        \\}}
        \\
    , .{ agent_source, project_source, library_source });
    defer allocator.free(trace_body);

    try writeTrace(tmp.dir, "rev", trace_body);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const res = try agent.executeShowWriter(allocator, root, "rev", buf.writer());
    try expectEqual(agent.ShowResult.ok, res);

    const out = buf.items;
    try expect(std.mem.indexOf(u8, out, "Agent: rev") != null);
    try expect(std.mem.indexOf(u8, out, "browser-tools (library v1.0.0)") != null);
    try expect(std.mem.indexOf(u8, out, "SKILL.md") != null);
    try expect(std.mem.indexOf(u8, out, "scripts/start.sh") != null);
    try expect(std.mem.indexOf(u8, out, "scripts/eval.sh") != null);
    try expect(std.mem.indexOf(u8, out, "[agent]") != null);
    try expect(std.mem.indexOf(u8, out, "[project]") != null);
    try expect(std.mem.indexOf(u8, out, "[library]") != null);
    // project/agent layers should show source path relative to project root.
    try expect(std.mem.indexOf(u8, out, "agents/rev/overrides/browser-tools/SKILL.md") != null);
    try expect(std.mem.indexOf(u8, out, "overrides/browser-tools/scripts/start.sh") != null);
    // Summary line.
    try expect(std.mem.indexOf(u8, out, "Files by layer: 1 library, 1 project, 1 agent") != null);
}

// ---------------- 2. missing trace.json ----------------

test "executeShowWriter: missing trace prints hint, returns no_trace" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFakeSandbox(tmp.dir);

    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const res = try agent.executeShowWriter(allocator, root, "ghost", buf.writer());
    try expectEqual(agent.ShowResult.no_trace, res);

    const out = buf.items;
    try expect(std.mem.indexOf(u8, out, "No runtime trace for agent 'ghost'") != null);
    try expect(std.mem.indexOf(u8, out, "mc run ghost --dry-run") != null);
}

// ---------------- 3. multiple capabilities, sorted ----------------

test "executeShowWriter: lists multiple caps in JSON order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFakeSandbox(tmp.dir);

    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);

    // writeTrace sorts capabilities alphabetically: "alpha", "beta", "gamma".
    const trace_body =
        \\{
        \\  "agent": "multi",
        \\  "generated_at": "2026-04-11T00:00:00Z",
        \\  "capabilities": [
        \\    { "name": "alpha", "library_version": "0.1.0", "files": [
        \\      { "path": "SKILL.md", "layer": "library", "source": "/x/alpha/SKILL.md" }
        \\    ] },
        \\    { "name": "beta", "library_version": null, "files": [
        \\      { "path": "SKILL.md", "layer": "library", "source": "/x/beta/SKILL.md" }
        \\    ] },
        \\    { "name": "gamma", "library_version": "2.0.0", "files": [
        \\      { "path": "SKILL.md", "layer": "library", "source": "/x/gamma/SKILL.md" }
        \\    ] }
        \\  ]
        \\}
        \\
    ;
    try writeTrace(tmp.dir, "multi", trace_body);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const res = try agent.executeShowWriter(allocator, root, "multi", buf.writer());
    try expectEqual(agent.ShowResult.ok, res);

    const out = buf.items;
    const a_idx = std.mem.indexOf(u8, out, "alpha ").?;
    const b_idx = std.mem.indexOf(u8, out, "beta ").?;
    const g_idx = std.mem.indexOf(u8, out, "gamma ").?;
    try expect(a_idx < b_idx);
    try expect(b_idx < g_idx);
}

// ---------------- 4. summary counts ----------------

test "executeShowWriter: summary line reflects layer counts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFakeSandbox(tmp.dir);

    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);

    // 3 library + 2 project + 1 agent = 6 files total.
    const trace_body =
        \\{
        \\  "agent": "counts",
        \\  "generated_at": "2026-04-11T00:00:00Z",
        \\  "capabilities": [
        \\    { "name": "cap", "library_version": "1.0.0", "files": [
        \\      { "path": "a", "layer": "library", "source": "/x/a" },
        \\      { "path": "b", "layer": "library", "source": "/x/b" },
        \\      { "path": "c", "layer": "library", "source": "/x/c" },
        \\      { "path": "d", "layer": "project", "source": "/x/d" },
        \\      { "path": "e", "layer": "project", "source": "/x/e" },
        \\      { "path": "f", "layer": "agent",   "source": "/x/f" }
        \\    ] }
        \\  ]
        \\}
        \\
    ;
    try writeTrace(tmp.dir, "counts", trace_body);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const res = try agent.executeShowWriter(allocator, root, "counts", buf.writer());
    try expectEqual(agent.ShowResult.ok, res);

    try expect(std.mem.indexOf(
        u8,
        buf.items,
        "Files by layer: 3 library, 2 project, 1 agent",
    ) != null);
}

// ---------------- 5. null library_version ----------------

test "executeShowWriter: null library_version renders without version" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFakeSandbox(tmp.dir);

    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);

    const trace_body =
        \\{
        \\  "agent": "nv",
        \\  "generated_at": "2026-04-11T00:00:00Z",
        \\  "capabilities": [
        \\    { "name": "nover", "library_version": null, "files": [
        \\      { "path": "SKILL.md", "layer": "library", "source": "/x/nover/SKILL.md" }
        \\    ] }
        \\  ]
        \\}
        \\
    ;
    try writeTrace(tmp.dir, "nv", trace_body);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const res = try agent.executeShowWriter(allocator, root, "nv", buf.writer());
    try expectEqual(agent.ShowResult.ok, res);

    const out = buf.items;
    // Header line should be exactly "nover (library)" — no "v<something>".
    try expect(std.mem.indexOf(u8, out, "nover (library)\n") != null);
    try expect(std.mem.indexOf(u8, out, "nover (library v") == null);
}

// ---------------- 6. non-sandbox ----------------

test "executeShowWriter: non-sandbox prints helpful message gracefully" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Note: no initFakeSandbox — .mc/mc.json absent.

    const root = try tmpPath(allocator, &tmp);
    defer allocator.free(root);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const res = try agent.executeShowWriter(allocator, root, "foo", buf.writer());
    try expectEqual(agent.ShowResult.not_a_sandbox, res);
    try expect(std.mem.indexOf(u8, buf.items, "Not an mc project") != null);
}
