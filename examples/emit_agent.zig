//! Example consumer of the `mc` library.
//!
//! Parses an in-memory `agent.json` (the cross-runtime superset) and emits the
//! native config for several managed-agent runtimes.
//!
//!     zig build example
//!
//! See `src/root.zig` for the full public API and `docs/agent-config-superset.md`
//! for the configuration model.

const std = @import("std");
const mc = @import("mc");

const AGENT_JSON =
    \\{
    \\  "name": "reviewer",
    \\  "description": "Reviews pull requests",
    \\  "model": "claude-opus-4-7",
    \\  "provider": "anthropic",
    \\  "thinking": "high",
    \\  "prompt": "./prompt.md",
    \\  "capabilities": { "skills": ["code-review"], "commands": [], "extensions": [], "toolset": "read-only" },
    \\  "env": { "required": ["ANTHROPIC_API_KEY"], "optional": [] },
    \\  "system": "You are a careful code reviewer.",
    \\  "permissions": { "default": "always_allow" },
    \\  "mcp_servers": { "linear": { "url": "https://mcp.linear.app/sse" } },
    \\  "multiagent": { "delegates": ["tester"] }
    \\}
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Parse + validate the agent config.
    var diags = mc.io.diagnostic.Diagnostics.init(a);
    defer diags.deinit();
    const agent = (try mc.schema.agent.parseAgent(a, "agent.json", AGENT_JSON, &diags)) orelse {
        std.debug.print("invalid agent.json ({d} diagnostics)\n", .{diags.count()});
        return error.InvalidAgent;
    };

    // 2. Emit native config for each managed-agent runtime.
    const claude = try mc.core.emit.emitClaude(a, agent, agent.system orelse "");
    const openclaw = try mc.core.emit.emitOpenclaw(a, agent, agent.system orelse "");
    const hermes = try mc.core.emit.emitHermes(a, agent, "");

    std.debug.print("# Claude Managed Agents (agents.create body)\n{s}\n\n", .{claude});
    std.debug.print("# OpenClaw (agents.list[] entry)\n{s}\n\n", .{openclaw});
    std.debug.print("# Hermes (config.yaml)\n{s}\n", .{hermes});

    // 3. Report anything a target couldn't represent.
    for (try mc.core.emit.warnings(a, agent, .claude)) |msg|
        std.debug.print("warning [claude]: {s}\n", .{msg});
}
