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

test "provider: invalid-format errors; unknown-but-valid name only warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Bad format (uppercase/space) → hard error, agent rejected.
    {
        var d = diag.Diagnostics.init(std.testing.allocator);
        defer d.deinit();
        const src =
            \\{
            \\  "name": "x", "description": "x", "model": "x",
            \\  "provider": "Bad Provider", "thinking": "off", "prompt": "x",
            \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
            \\  "env": { "required": [], "optional": [] }
            \\}
        ;
        const a = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
        try std.testing.expect(a == null);
        try std.testing.expect(d.hasErrors());
        try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "provider"));
    }

    // Deployment-defined name (e.g. "local-llm") → valid; warns, but parses.
    {
        var d = diag.Diagnostics.init(std.testing.allocator);
        defer d.deinit();
        const src =
            \\{
            \\  "name": "x", "description": "x", "model": "minimax-m2.7",
            \\  "provider": "local-llm", "thinking": "off", "prompt": "x",
            \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
            \\  "env": { "required": [], "optional": [] }
            \\}
        ;
        const a = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
        try std.testing.expect(a != null);
        try std.testing.expect(!d.hasErrors());
        try std.testing.expectEqualStrings("local-llm", a.?.provider);
        try std.testing.expect(messagesContain(&d, "not a built-in"));
    }
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
        \\  "provider": "Bad Provider",
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

// ---- superset (managed-agent) fields ----

test "minimal agent has no superset fields and defaults runtime to pi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const a = (try agent.parseAgent(arena.allocator(), "agent.json", VALID_MINIMAL, &d)).?;
    try std.testing.expect(a.runtime == null);
    try std.testing.expect(a.system == null);
    try std.testing.expect(a.tools == null);
    try std.testing.expect(a.sandbox == null);
    try std.testing.expect(a.metadata == null);
    try std.testing.expect(a.targets == null);
    try std.testing.expectEqualStrings("pi", agent.effectiveRuntime(a));
}

const VALID_SUPERSET =
    \\{
    \\  "name": "reviewer",
    \\  "description": "Reviews PRs",
    \\  "model": "claude-opus-4-7",
    \\  "provider": "anthropic",
    \\  "thinking": "high",
    \\  "prompt": "./prompt.md",
    \\  "capabilities": { "skills": ["review"], "commands": [], "extensions": [], "toolset": "read-only" },
    \\  "env": { "required": ["ANTHROPIC_API_KEY"], "optional": [], "vars": { "FOO": "bar" } },
    \\  "runtime": "claude",
    \\  "system": "You are careful.",
    \\  "speed": "fast",
    \\  "max_tokens": 8192,
    \\  "temperature": 0.2,
    \\  "context_window": 200000,
    \\  "max_turns": 60,
    \\  "api_key_env": "ANTHROPIC_API_KEY",
    \\  "base_url": "https://api.anthropic.com",
    \\  "mcp": ["linear", "github"],
    \\  "tools": { "allow": ["read", "grep"], "deny": ["bash"], "builtin": true },
    \\  "permissions": { "default": "ask", "rules": { "read": "always_allow" } },
    \\  "sandbox": { "backend": "anthropic", "image": "node:22", "cpu": 2, "memory": 4096, "network": "restricted", "workdir": "/workspace" },
    \\  "memory": { "enabled": true, "backend": "store" },
    \\  "multiagent": { "delegates": ["researcher", "tester"] },
    \\  "metadata": { "team": "infra" },
    \\  "targets": { "claude": { "mcp_servers": [] }, "hermes": { "terminal": { "backend": "docker" } } }
    \\}
;

test "full superset agent parses every field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const a = (try agent.parseAgent(arena.allocator(), "agent.json", VALID_SUPERSET, &d)) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(!d.hasErrors());

    try std.testing.expectEqualStrings("claude", a.runtime.?);
    try std.testing.expectEqualStrings("claude", agent.effectiveRuntime(a));
    try std.testing.expectEqualStrings("You are careful.", a.system.?);
    try std.testing.expectEqualStrings("fast", a.speed.?);
    try std.testing.expectEqual(@as(i64, 8192), a.max_tokens.?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), a.temperature.?, 0.0001);
    try std.testing.expectEqual(@as(i64, 200000), a.context_window.?);
    try std.testing.expectEqual(@as(i64, 60), a.max_turns.?);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", a.api_key_env.?);
    try std.testing.expectEqualStrings("https://api.anthropic.com", a.base_url.?);

    try std.testing.expectEqual(@as(usize, 2), a.mcp.len);
    try std.testing.expectEqualStrings("linear", a.mcp[0]);

    try std.testing.expect(a.tools != null);
    try std.testing.expectEqual(@as(usize, 2), a.tools.?.allow.len);
    try std.testing.expectEqual(@as(usize, 1), a.tools.?.deny.len);
    try std.testing.expectEqual(true, a.tools.?.builtin.?);

    try std.testing.expectEqualStrings("ask", a.permissions.?.default.?);
    try std.testing.expect(a.permissions.?.rules != null);

    try std.testing.expectEqualStrings("anthropic", a.sandbox.?.backend.?);
    try std.testing.expectEqual(@as(i64, 2), a.sandbox.?.cpu.?);
    try std.testing.expectEqual(@as(i64, 4096), a.sandbox.?.memory.?);
    try std.testing.expectEqualStrings("restricted", a.sandbox.?.network.?);

    try std.testing.expectEqual(true, a.memory.?.enabled.?);
    try std.testing.expectEqual(@as(usize, 2), a.multiagent.?.delegates.len);
    try std.testing.expect(a.metadata != null);
    try std.testing.expect(a.targets != null);
    try std.testing.expect(a.env.vars != null);
}

test "extended providers accepted (google/xai/bedrock)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "google", "xai", "bedrock", "groq" }) |prov| {
        var d = diag.Diagnostics.init(std.testing.allocator);
        defer d.deinit();
        const src = try std.fmt.allocPrint(arena.allocator(),
            \\{{
            \\  "name": "x", "description": "x", "model": "m",
            \\  "provider": "{s}", "thinking": "off", "prompt": "p",
            \\  "capabilities": {{ "skills": [], "commands": [], "extensions": [], "toolset": "x" }},
            \\  "env": {{ "required": [], "optional": [] }}
            \\}}
        , .{prov});
        const a = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
        try std.testing.expect(a != null);
        try std.testing.expect(!d.hasErrors());
    }
}

test "bogus runtime / sandbox.network / permissions.default rejected by enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "x", "description": "x", "model": "m",
        \\  "provider": "anthropic", "thinking": "off", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "runtime": "wrenchbot",
        \\  "sandbox": { "network": "wide-open" },
        \\  "permissions": { "default": "maybe" }
        \\}
    ;
    _ = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "runtime"));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "sandbox.network"));
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "permissions.default"));
}

test "unknown superset key is still reported (strict)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "x", "description": "x", "model": "m",
        \\  "provider": "anthropic", "thinking": "off", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "runtimes": "claude"
        \\}
    ;
    _ = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
    try std.testing.expect(messagesContain(&d, "unknown key 'runtimes'"));
}

test "max_turns must be a positive integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "x", "description": "x", "model": "m",
        \\  "provider": "anthropic", "thinking": "off", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "max_turns": 0
        \\}
    ;
    _ = try agent.parseAgent(arena.allocator(), "agent.json", src, &d);
    try std.testing.expectEqual(@as(usize, 1), pathCount(&d, "max_turns"));
    try std.testing.expect(messagesContain(&d, "positive integer"));
}
