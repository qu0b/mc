const std = @import("std");
const diag = @import("diagnostic");
const agent = @import("agent");
const emit = @import("emit");

fn parse(arena: std.mem.Allocator, src: []const u8) !agent.Agent {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();
    const a = try agent.parseAgent(arena, "agent.json", src, &d);
    try std.testing.expect(!d.hasErrors());
    return a.?;
}

const BASE =
    \\{
    \\  "name": "reviewer",
    \\  "description": "Reviews PRs",
    \\  "model": "claude-opus-4-7",
    \\  "provider": "anthropic",
    \\  "thinking": "high",
    \\  "prompt": "./prompt.md",
    \\  "capabilities": { "skills": ["review"], "commands": [], "extensions": [], "toolset": "read-only" },
    \\  "env": { "required": [], "optional": [] }
    \\}
;

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

test "emitClaude: minimal body is valid JSON with core fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try parse(arena.allocator(), BASE);

    const json = try emit.emitClaude(arena.allocator(), a, "PROMPT BODY");

    // Re-parse to assert it is well-formed and structurally correct.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    const o = v.object;
    try std.testing.expectEqualStrings("reviewer", o.get("name").?.string);
    try std.testing.expectEqualStrings("claude-opus-4-7", o.get("model").?.string); // string (no speed)
    try std.testing.expectEqualStrings("PROMPT BODY", o.get("system").?.string); // falls back to prompt text
    try std.testing.expectEqualStrings("Reviews PRs", o.get("description").?.string);

    // tools: just the prebuilt toolset, no mcp.
    const tools = o.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    try std.testing.expectEqualStrings("agent_toolset_20260401", tools.items[0].object.get("type").?.string);

    // skills carried through.
    try std.testing.expectEqual(@as(usize, 1), o.get("skills").?.array.items.len);
}

test "emitClaude: speed produces a model object, mcp refs produce mcp_toolset tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "a", "description": "d", "model": "claude-opus-4-7",
        \\  "provider": "anthropic", "thinking": "high", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "speed": "fast",
        \\  "system": "Inline system",
        \\  "mcp": ["linear", "github"]
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const json = try emit.emitClaude(arena.allocator(), a, "unused");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    const o = v.object;

    // model is an object { id, speed }.
    const m = o.get("model").?.object;
    try std.testing.expectEqualStrings("claude-opus-4-7", m.get("id").?.string);
    try std.testing.expectEqualStrings("fast", m.get("speed").?.string);

    // inline system wins over prompt text.
    try std.testing.expectEqualStrings("Inline system", o.get("system").?.string);

    // tools: agent_toolset + 2 mcp_toolset entries.
    const tools = o.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 3), tools.items.len);
    try std.testing.expectEqualStrings("mcp_toolset", tools.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("linear", tools.items[1].object.get("mcp_server_name").?.string);
    try std.testing.expectEqualStrings("github", tools.items[2].object.get("mcp_server_name").?.string);
}

test "emitClaude: multiagent + metadata + targets passthrough merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "a", "description": "d", "model": "claude-opus-4-7",
        \\  "provider": "anthropic", "thinking": "high", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "multiagent": { "delegates": ["researcher", "tester"] },
        \\  "metadata": { "team": "infra" },
        \\  "targets": {
        \\    "claude": {
        \\      "model": "claude-sonnet-4-6",
        \\      "mcp_servers": [ { "type": "url", "name": "linear", "url": "https://mcp.linear.app/sse" } ]
        \\    }
        \\  }
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const json = try emit.emitClaude(arena.allocator(), a, "unused");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    const o = v.object;

    // multiagent → { agents: [...] }.
    try std.testing.expectEqual(@as(usize, 2), o.get("multiagent").?.object.get("agents").?.array.items.len);
    // metadata carried through.
    try std.testing.expectEqualStrings("infra", o.get("metadata").?.object.get("team").?.string);
    // targets.claude.model OVERRIDES the canonical model.
    try std.testing.expectEqualStrings("claude-sonnet-4-6", o.get("model").?.string);
    // targets.claude.mcp_servers added (a key the superset doesn't model itself).
    try std.testing.expectEqual(@as(usize, 1), o.get("mcp_servers").?.array.items.len);
}

test "emitPiArgv: faithful loadout + system prompt + skill dirs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "a", "description": "d", "model": "claude-haiku-4.5",
        \\  "provider": "openrouter", "thinking": "medium", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "system": "Be terse."
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const argv = try emit.emitPiArgv(
        arena.allocator(),
        a,
        &.{ "read", "grep" },
        &.{ "/rt/reviewer/skill-a", "/rt/reviewer/skill-b" },
        "do the thing",
        &.{"--offline"},
    );

    try std.testing.expectEqualStrings("pi", argv[0]);
    try std.testing.expectEqualStrings("-p", argv[1]);
    try std.testing.expectEqualStrings("do the thing", argv[2]);

    try std.testing.expect(argvContains(argv, "--system-prompt"));
    try std.testing.expect(argvContains(argv, "Be terse."));
    try std.testing.expect(argvContains(argv, "--provider"));
    try std.testing.expect(argvContains(argv, "openrouter"));
    try std.testing.expect(argvContains(argv, "--model"));
    try std.testing.expect(argvContains(argv, "claude-haiku-4.5"));
    try std.testing.expect(argvContains(argv, "--thinking"));
    try std.testing.expect(argvContains(argv, "read,grep"));
    try std.testing.expect(argvContains(argv, "--no-skills"));
    try std.testing.expect(argvContains(argv, "--no-extensions"));
    try std.testing.expect(argvContains(argv, "/rt/reviewer/skill-b"));
    try std.testing.expect(argvContains(argv, "--offline"));
}

test "emitPiArgv: tools.builtin=false adds --no-builtin-tools and max_tokens flows through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "a", "description": "d", "model": "m",
        \\  "provider": "openrouter", "thinking": "low", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "max_tokens": 2048,
        \\  "tools": { "builtin": false }
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const argv = try emit.emitPiArgv(arena.allocator(), a, &.{"read"}, &.{}, "msg", &.{});
    try std.testing.expect(argvContains(argv, "--no-builtin-tools"));
    try std.testing.expect(argvContains(argv, "--max-tokens"));
    try std.testing.expect(argvContains(argv, "2048"));
}

test "emitPiArgv: no system flag when system absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = try parse(arena.allocator(), BASE);
    const argv = try emit.emitPiArgv(arena.allocator(), a, &.{"read"}, &.{}, "msg", &.{});
    try std.testing.expect(!argvContains(argv, "--system-prompt"));
}

test "emitOpenclaw: agent entry fields + tools + targets merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "rev", "description": "d", "model": "claude-opus-4-7",
        \\  "provider": "anthropic", "thinking": "medium", "prompt": "p",
        \\  "capabilities": { "skills": ["review"], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "tools": { "allow": ["read", "grep"], "deny": ["bash"] },
        \\  "sandbox": { "backend": "docker", "workdir": "/workspace" },
        \\  "targets": { "openclaw": { "default": true } }
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const json = try emit.emitOpenclaw(arena.allocator(), a, "PROMPT");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    const o = v.object;

    try std.testing.expectEqualStrings("rev", o.get("id").?.string);
    try std.testing.expectEqualStrings("PROMPT", o.get("systemPromptOverride").?.string);
    try std.testing.expectEqualStrings("medium", o.get("thinkingDefault").?.string);
    try std.testing.expectEqual(@as(usize, 2), o.get("tools").?.object.get("allow").?.array.items.len);
    try std.testing.expectEqualStrings("docker", o.get("sandbox").?.object.get("backend").?.string);
    try std.testing.expectEqual(true, o.get("default").?.bool); // targets.openclaw merged
}

test "parseTarget recognizes known runtimes" {
    try std.testing.expectEqual(emit.Target.claude, emit.parseTarget("claude").?);
    try std.testing.expectEqual(emit.Target.pi, emit.parseTarget("pi").?);
    try std.testing.expectEqual(emit.Target.openclaw, emit.parseTarget("openclaw").?);
    try std.testing.expectEqual(emit.Target.hermes, emit.parseTarget("hermes").?);
    try std.testing.expect(emit.parseTarget("nope") == null);
}

test "emitClaude: deep-merges nested target override and honors JSON null deletion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "a", "description": "keep me", "model": "claude-opus-4-7",
        \\  "provider": "anthropic", "thinking": "high", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "metadata": { "team": "infra", "tier": "gold" },
        \\  "targets": { "claude": { "metadata": { "team": null, "org": "acme" }, "description": null } }
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const json = try emit.emitClaude(arena.allocator(), a, "P");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    const o = v.object;

    // description deleted by null.
    try std.testing.expect(o.get("description") == null);
    // metadata DEEP-merged: team removed (null), tier preserved, org added.
    const md = o.get("metadata").?.object;
    try std.testing.expect(md.get("team") == null);
    try std.testing.expectEqualStrings("gold", md.get("tier").?.string);
    try std.testing.expectEqualStrings("acme", md.get("org").?.string);
}

test "emitClaude: mcp_servers definitions become url connectors + toolset refs; permissions become a policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "a", "description": "d", "model": "claude-opus-4-7",
        \\  "provider": "anthropic", "thinking": "high", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "permissions": { "default": "ask" },
        \\  "mcp_servers": {
        \\    "linear": { "url": "https://mcp.linear.app/sse", "type": "url" },
        \\    "fs": { "command": "mcp-fs", "args": ["--root", "/w"] }
        \\  }
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const json = try emit.emitClaude(arena.allocator(), a, "P");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    const o = v.object;

    // Only the url server is emitted (stdio "fs" omitted).
    const servers = o.get("mcp_servers").?.array;
    try std.testing.expectEqual(@as(usize, 1), servers.items.len);
    try std.testing.expectEqualStrings("linear", servers.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("https://mcp.linear.app/sse", servers.items[0].object.get("url").?.string);
    // stdio-only keys must not leak into the Claude connector.
    try std.testing.expect(servers.items[0].object.get("command") == null);

    // tools: agent_toolset (with permission policy) + a toolset ref per attached server.
    const tools = o.get("tools").?.array;
    const dc = tools.items[0].object.get("default_config").?.object;
    try std.testing.expectEqualStrings("ask", dc.get("permission_policy").?.object.get("type").?.string);
    // attach-all (no `mcp` allowlist) attaches only emittable url servers, so
    // the stdio "fs" gets no dangling toolset ref: agent_toolset + linear only.
    try std.testing.expectEqual(@as(usize, 2), tools.items.len);
    try std.testing.expectEqualStrings("mcp_toolset", tools.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("linear", tools.items[1].object.get("mcp_server_name").?.string);
}

test "warnings: claude flags dropped fields but not honored permissions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "a", "description": "d", "model": "m",
        \\  "provider": "anthropic", "thinking": "high", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "permissions": { "default": "ask" },
        \\  "sandbox": { "backend": "anthropic" },
        \\  "tools": { "allow": ["read"] },
        \\  "max_tokens": 4096,
        \\  "base_url": "https://x"
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const warns = try emit.warnings(arena.allocator(), a, .claude);
    try std.testing.expect(warnsContain(warns, "sandbox"));
    try std.testing.expect(warnsContain(warns, "tools.allow/deny"));
    try std.testing.expect(warnsContain(warns, "max_tokens"));
    try std.testing.expect(warnsContain(warns, "base_url"));
    // permissions IS honored for Claude → must not warn.
    try std.testing.expect(!warnsContain(warns, "permission"));
}

test "warnings: openclaw flags mcp + permissions; clean config warns nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dirty =
        \\{
        \\  "name": "a", "description": "d", "model": "m",
        \\  "provider": "anthropic", "thinking": "high", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "permissions": { "default": "ask" },
        \\  "mcp": ["linear"]
        \\}
    ;
    const a = try parse(arena.allocator(), dirty);
    const warns = try emit.warnings(arena.allocator(), a, .openclaw);
    try std.testing.expect(warnsContain(warns, "MCP"));
    try std.testing.expect(warnsContain(warns, "permissions"));

    const clean = try emit.warnings(arena.allocator(), try parse(arena.allocator(), BASE), .openclaw);
    try std.testing.expectEqual(@as(usize, 0), clean.len);
}

test "emitHermes: maps model/agent/mcp/terminal/memory into config.yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "h", "description": "d", "model": "claude-opus-4-7",
        \\  "provider": "anthropic", "thinking": "high", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "max_tokens": 8192, "context_window": 200000,
        \\  "mcp_servers": { "linear": { "url": "https://mcp.linear.app/sse" } },
        \\  "sandbox": { "backend": "docker", "image": "python:3.12" },
        \\  "memory": { "enabled": true }
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const yaml = try emit.emitHermes(arena.allocator(), a, "unused");
    try std.testing.expect(contains(yaml, "model:\n  default: \"claude-opus-4-7\"\n  provider: \"anthropic\""));
    try std.testing.expect(contains(yaml, "max_tokens: 8192"));
    try std.testing.expect(contains(yaml, "context_length: 200000"));
    try std.testing.expect(contains(yaml, "agent:\n  reasoning_effort: \"high\""));
    try std.testing.expect(contains(yaml, "mcp_servers:\n  linear:\n    url: \"https://mcp.linear.app/sse\""));
    try std.testing.expect(contains(yaml, "terminal:\n  backend: \"docker\"\n  docker_image: \"python:3.12\""));
    try std.testing.expect(contains(yaml, "memory:\n  memory_enabled: true"));
}

test "emitHermes: cloud sandbox backend is dropped with a warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "h", "description": "d", "model": "m",
        \\  "provider": "anthropic", "thinking": "high", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "sandbox": { "backend": "anthropic" }
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const yaml = try emit.emitHermes(arena.allocator(), a, "u");
    try std.testing.expect(!contains(yaml, "terminal:"));
    const warns = try emit.warnings(arena.allocator(), a, .hermes);
    try std.testing.expect(warnsContain(warns, "Hermes terminal backend"));
}

// A golden test locks the exact Claude wire shape for a minimal agent, so an
// accidental change to field order/structure is caught loudly.
test "emitClaude: golden minimal body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "g", "description": "d", "model": "claude-opus-4-7",
        \\  "provider": "anthropic", "thinking": "high", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] }
        \\}
    ;
    const a = try parse(arena.allocator(), src);
    const json = try emit.emitClaude(arena.allocator(), a, "You are g.");
    const golden =
        \\{
        \\  "name": "g",
        \\  "model": "claude-opus-4-7",
        \\  "system": "You are g.",
        \\  "description": "d",
        \\  "tools": [
        \\    {
        \\      "type": "agent_toolset_20260401"
        \\    }
        \\  ]
        \\}
    ;
    try std.testing.expectEqualStrings(golden, json);
}

test "emitPiModels: pins the exact provider + model id; never embeds the key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\{
        \\  "name": "rev", "description": "d", "model": "minimax-m2.7",
        \\  "provider": "local-llm", "thinking": "off", "prompt": "p",
        \\  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "x" },
        \\  "env": { "required": [], "optional": [] },
        \\  "base_url": "https://ai.starflinger.eu",
        \\  "api": "anthropic-messages",
        \\  "api_key_env": "LITELLM_KEY",
        \\  "context_window": 196608, "max_tokens": 64000, "reasoning": true
        \\}
    ;
    const a = try parse(arena.allocator(), src); // local-llm warns but parses

    // Shareable form (no key): exact provider/model pinned, secret absent.
    const json = try emit.emitPiModels(arena.allocator(), a, null);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    const prov = v.object.get("providers").?.object.get("local-llm").?.object;
    try std.testing.expectEqualStrings("https://ai.starflinger.eu", prov.get("baseUrl").?.string);
    try std.testing.expectEqualStrings("anthropic-messages", prov.get("api").?.string);
    const m = prov.get("models").?.array.items[0].object;
    try std.testing.expectEqualStrings("minimax-m2.7", m.get("id").?.string); // exact, not fuzzy
    try std.testing.expectEqual(@as(i64, 196608), m.get("contextWindow").?.integer);
    try std.testing.expectEqual(@as(i64, 64000), m.get("maxTokens").?.integer);
    try std.testing.expectEqual(true, m.get("reasoning").?.bool);
    try std.testing.expect(prov.get("apiKey") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "LITELLM_KEY") == null);

    // Materialize form (key injected): apiKey present, exactly the value given.
    const json_key = try emit.emitPiModels(arena.allocator(), a, "sk-secret-123");
    const vk = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json_key, .{});
    try std.testing.expectEqualStrings(
        "sk-secret-123",
        vk.object.get("providers").?.object.get("local-llm").?.object.get("apiKey").?.string,
    );

    // settings.json pins defaults so pi needs no --provider/--model flags.
    const settings = try emit.emitPiSettings(arena.allocator(), a);
    const sv = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), settings, .{});
    try std.testing.expectEqualStrings("local-llm", sv.object.get("defaultProvider").?.string);
    try std.testing.expectEqualStrings("minimax-m2.7", sv.object.get("defaultModel").?.string);
    try std.testing.expectEqualStrings("off", sv.object.get("defaultThinkingLevel").?.string);

    const warns = try emit.warnings(arena.allocator(), a, .pi);
    try std.testing.expect(warnsContain(warns, "$LITELLM_KEY"));
}

fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |a| if (std.mem.eql(u8, a, needle)) return true;
    return false;
}

fn warnsContain(warns: []const []const u8, needle: []const u8) bool {
    for (warns) |wmsg| if (std.mem.indexOf(u8, wmsg, needle) != null) return true;
    return false;
}
