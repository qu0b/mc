const std = @import("std");
const diag = @import("diagnostic");
const agent = @import("agent");

fn messagesContain(diags: *const diag.Diagnostics, needle: []const u8) bool {
    for (diags.items.items) |it| {
        if (std.mem.indexOf(u8, it.message, needle) != null) return true;
    }
    return false;
}

fn pathCount(diags: *const diag.Diagnostics, path: []const u8) usize {
    var n: usize = 0;
    for (diags.items.items) |it| {
        if (std.mem.eql(u8, it.path, path)) n += 1;
    }
    return n;
}

const VALID_MINIMAL =
    \\{
    \\  "name": "my-agent",
    \\  "description": "Does things",
    \\  "model": "claude-sonnet-4",
    \\  "provider": "anthropic",
    \\  "thinking": "medium",
    \\  "prompt": "./prompt.md",
    \\  "capabilities": {
    \\    "skills": ["review"],
    \\    "commands": ["/build"],
    \\    "extensions": ["vscode"],
    \\    "toolset": "read-only"
    \\  },
    \\  "env": {
    \\    "required": ["ANTHROPIC_API_KEY"],
    \\    "optional": []
    \\  }
    \\}
;

test "valid minimal agent passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const a = try agent.parseAgent(arena.allocator(), "agent.json", VALID_MINIMAL, &d);
    try std.testing.expect(a != null);
    try std.testing.expect(!d.hasErrors());
    try std.testing.expectEqualStrings("my-agent", a.?.name);
    try std.testing.expectEqualStrings("anthropic", a.?.provider);
    try std.testing.expectEqualStrings("read-only", a.?.capabilities.toolset);
}

test "missing required fields produce diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const result = try agent.parseAgent(arena.allocator(), "agent.json", "{}", &d);
    try std.testing.expect(result == null);
    try std.testing.expect(d.hasErrors());
    // All 8 required top-level fields missing
    try std.testing.expect(messagesContain(&d, "'name'"));
    try std.testing.expect(messagesContain(&d, "'description'"));
    try std.testing.expect(messagesContain(&d, "'model'"));
    try std.testing.expect(messagesContain(&d, "'provider'"));
    try std.testing.expect(messagesContain(&d, "'thinking'"));
    try std.testing.expect(messagesContain(&d, "'prompt'"));
    try std.testing.expect(messagesContain(&d, "'capabilities'"));
    try std.testing.expect(messagesContain(&d, "'env'"));
}

test "unknown top-level field is reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "x", "description": "x", "model": "x",
        \\  "provider": "anthropic", "thinking": "off", "prompt": "x",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "bogus": true
        \\}
    ;
    _ = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
    try std.testing.expect(messagesContain(&d, "unknown key 'bogus'"));
}

test "bogus provider triggers enum error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "x", "description": "x", "model": "x",
        \\  "provider": "bogus", "thinking": "off", "prompt": "x",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] }
        \\}
    ;
    _ = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
    try std.testing.expect(messagesContain(&d, "must be one of:"));
    try std.testing.expect(messagesContain(&d, "openrouter"));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "provider"));
}

test "env var identifier rules: ok_var, BadVar, 123ABC all rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "x", "description": "x", "model": "x",
        \\  "provider": "anthropic", "thinking": "off", "prompt": "x",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": ["ok_var", "BadVar", "123ABC", "OK_VAR"], "optional": [] }
        \\}
    ;
    _ = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
    // OK_VAR passes; the other three fail.
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "env.required[0]"));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "env.required[1]"));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "env.required[2]"));
    try std.testing.expectEqual(@as(usize, 0), pathCount(&d, "env.required[3]"));
}

test "command names: /ok, bad-no-slash, /Bad Case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "x", "description": "x", "model": "x",
        \\  "provider": "anthropic", "thinking": "off", "prompt": "x",
        \\  "capabilities": {
        \\    "skills": [], "extensions": [], "toolset": "x",
        \\    "commands": ["/ok", "bad-no-slash", "/Bad Case"]
        \\  },
        \\  "env": { "required": [], "optional": [] }
        \\}
    ;
    _ = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
    try std.testing.expectEqual(@as(usize, 0), pathCount(&d, "capabilities.commands[0]"));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "capabilities.commands[1]"));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "capabilities.commands[2]"));
}

test "multiple errors across fields all captured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "Bad-Case",
        \\  "description": "",
        \\  "model": "m",
        \\  "provider": "gemini",
        \\  "thinking": "turbo",
        \\  "prompt": "",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] }
        \\}
    ;
    _ = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
    // Expected errors: name (slug), description (empty), provider (enum), thinking (enum), prompt (empty)
    try std.testing.expect(d.count() >= 5);
}

test "session field accepts partial config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "x", "description": "x", "model": "x",
        \\  "provider": "anthropic", "thinking": "off", "prompt": "x",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "session": { "export": true, "r2_bucket": "my-bucket" }
        \\}
    ;
    const a = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
    try std.testing.expect(a != null);
    try std.testing.expect(!d.hasErrors());
    try std.testing.expect(a.?.session != null);
    try std.testing.expectEqual(true, a.?.session.?.@"export".?);
    try std.testing.expectEqualStrings("my-bucket", a.?.session.?.r2_bucket.?);
}
