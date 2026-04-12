const std = @import("std");
const agent = @import("agent");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

// ---------------- slug validation ----------------

test "isValidSlug: accepts lowercase start" {
    try expect(agent.isValidSlug("foo"));
    try expect(agent.isValidSlug("a"));
    try expect(agent.isValidSlug("my-agent"));
    try expect(agent.isValidSlug("agent-123"));
}

test "isValidSlug: rejects uppercase, leading digit, empty" {
    try expect(!agent.isValidSlug(""));
    try expect(!agent.isValidSlug("FOO"));
    try expect(!agent.isValidSlug("Foo"));
    try expect(!agent.isValidSlug("1foo"));
    try expect(!agent.isValidSlug("-foo"));
    try expect(!agent.isValidSlug("foo bar"));
    try expect(!agent.isValidSlug("foo_bar"));
}

test "isValidSlug: length bounds" {
    // 63 chars: max allowed.
    const max = "a" ** 63;
    try expect(agent.isValidSlug(max));
    // 64 chars: rejected.
    const over = "a" ** 64;
    try expect(!agent.isValidSlug(over));
}

// ---------------- template rendering ----------------

test "renderAgentJson: name is interpolated" {
    const allocator = std.testing.allocator;
    const json = try agent.renderAgentJson(allocator, .{ .name = "my-agent" });
    defer allocator.free(json);
    try expect(std.mem.indexOf(u8, json, "\"name\": \"my-agent\"") != null);
}

test "renderAgentJson: default model / provider / toolset" {
    const allocator = std.testing.allocator;
    const json = try agent.renderAgentJson(allocator, .{ .name = "x" });
    defer allocator.free(json);
    try expect(std.mem.indexOf(u8, json, "\"model\": \"claude-haiku-4.5\"") != null);
    try expect(std.mem.indexOf(u8, json, "\"provider\": \"openrouter\"") != null);
    try expect(std.mem.indexOf(u8, json, "\"toolset\": \"read-only\"") != null);
}

test "renderAgentJson: --model override reflected" {
    const allocator = std.testing.allocator;
    const json = try agent.renderAgentJson(allocator, .{
        .name = "x",
        .model = "anthropic/claude-opus-4",
    });
    defer allocator.free(json);
    try expect(std.mem.indexOf(u8, json, "\"model\": \"anthropic/claude-opus-4\"") != null);
}

test "renderAgentJson: parses as valid JSON with required fields" {
    const allocator = std.testing.allocator;
    const json = try agent.renderAgentJson(allocator, .{ .name = "foo" });
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try expect(obj.get("name") != null);
    try expect(obj.get("description") != null);
    try expect(obj.get("model") != null);
    try expect(obj.get("provider") != null);
    try expect(obj.get("thinking") != null);
    try expect(obj.get("prompt") != null);
    try expect(obj.get("capabilities") != null);
    try expect(obj.get("env") != null);
    try expectEqualStrings("foo", obj.get("name").?.string);
}

test "renderPrompt: first line contains title-cased name" {
    const allocator = std.testing.allocator;
    const prompt = try agent.renderPrompt(allocator, "foo");
    defer allocator.free(prompt);
    // First line must be "# Foo Agent".
    const nl = std.mem.indexOfScalar(u8, prompt, '\n') orelse prompt.len;
    try expectEqualStrings("# Foo Agent", prompt[0..nl]);
}

test "renderPrompt: title-cases mixed input" {
    const allocator = std.testing.allocator;
    const prompt = try agent.renderPrompt(allocator, "my-agent");
    defer allocator.free(prompt);
    const nl = std.mem.indexOfScalar(u8, prompt, '\n') orelse prompt.len;
    try expectEqualStrings("# My-agent Agent", prompt[0..nl]);
}

// ---------------- scaffold integration (tmp dir) ----------------

/// Helper: init a fake mc sandbox (.mc/mc.json) inside the given dir.
fn initFakeSandbox(dir: std.fs.Dir) !void {
    try dir.makeDir(".mc");
    try dir.writeFile(.{
        .sub_path = ".mc/mc.json",
        .data = "{\"name\":\"test\"}\n",
    });
}

/// Helper: realpath of a TmpDir.
fn tmpPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    return tmp.dir.realpathAlloc(allocator, ".");
}

test "scaffoldAt: non-sandbox dir returns not_a_sandbox without creating files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmpPath(allocator, &tmp);
    defer allocator.free(path);

    const res = try agent.scaffoldAt(allocator, path, .{ .name = "foo" });
    try expectEqual(agent.ScaffoldResult.not_a_sandbox, res);

    // No agents/ directory created.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("agents", .{}));
}

test "scaffoldAt: fresh sandbox creates expected tree with valid JSON" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFakeSandbox(tmp.dir);

    const path = try tmpPath(allocator, &tmp);
    defer allocator.free(path);

    const res = try agent.scaffoldAt(allocator, path, .{ .name = "foo" });
    try expectEqual(agent.ScaffoldResult.created, res);

    // Directory tree.
    try tmp.dir.access("agents/foo/agent.json", .{});
    try tmp.dir.access("agents/foo/prompt.md", .{});
    try tmp.dir.access("agents/foo/overrides", .{});
    try tmp.dir.access("agents/foo/overrides/.gitkeep", .{});

    // agent.json is valid JSON and has "name": "foo".
    const json_bytes = try tmp.dir.readFileAlloc(allocator, "agents/foo/agent.json", 64 * 1024);
    defer allocator.free(json_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();
    try expectEqualStrings("foo", parsed.value.object.get("name").?.string);

    // prompt.md starts with "# Foo Agent".
    const prompt_bytes = try tmp.dir.readFileAlloc(allocator, "agents/foo/prompt.md", 64 * 1024);
    defer allocator.free(prompt_bytes);
    try expect(std.mem.startsWith(u8, prompt_bytes, "# Foo Agent"));
}

test "scaffoldAt: already existing agent is not overwritten" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFakeSandbox(tmp.dir);

    const path = try tmpPath(allocator, &tmp);
    defer allocator.free(path);

    _ = try agent.scaffoldAt(allocator, path, .{ .name = "foo" });

    // Tamper with the file to verify it's preserved on second call.
    try tmp.dir.writeFile(.{
        .sub_path = "agents/foo/agent.json",
        .data = "SENTINEL",
    });

    const res = try agent.scaffoldAt(allocator, path, .{ .name = "foo" });
    try expectEqual(agent.ScaffoldResult.already_exists, res);

    const after = try tmp.dir.readFileAlloc(allocator, "agents/foo/agent.json", 64 * 1024);
    defer allocator.free(after);
    try expectEqualStrings("SENTINEL", after);
}

test "scaffoldAt: invalid slug rejected and no agents dir populated" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFakeSandbox(tmp.dir);

    const path = try tmpPath(allocator, &tmp);
    defer allocator.free(path);

    const r1 = try agent.scaffoldAt(allocator, path, .{ .name = "FOO" });
    try expectEqual(agent.ScaffoldResult.invalid_name, r1);

    const r2 = try agent.scaffoldAt(allocator, path, .{ .name = "1foo" });
    try expectEqual(agent.ScaffoldResult.invalid_name, r2);

    // No agent directory created for the rejected slugs.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("agents/FOO", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("agents/1foo", .{}));
}

test "scaffoldAt: --model override is written to agent.json" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try initFakeSandbox(tmp.dir);

    const path = try tmpPath(allocator, &tmp);
    defer allocator.free(path);

    const res = try agent.scaffoldAt(allocator, path, .{
        .name = "bar",
        .model = "anthropic/claude-opus-4",
    });
    try expectEqual(agent.ScaffoldResult.created, res);

    const json = try tmp.dir.readFileAlloc(allocator, "agents/bar/agent.json", 64 * 1024);
    defer allocator.free(json);
    try expect(std.mem.indexOf(u8, json, "\"model\": \"anthropic/claude-opus-4\"") != null);
}
