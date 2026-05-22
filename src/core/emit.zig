//! Emitters: translate a canonical `agent.json` (the cross-runtime superset)
//! into each managed-agent runtime's native configuration.
//!
//! Each JSON emitter deep-merges the matching `targets.<runtime>` object over
//! its canonical output (RFC 7386 JSON Merge Patch: objects merge recursively,
//! arrays/scalars replace, a JSON `null` deletes a key), so any runtime field
//! is expressible — even nested overrides — without extending the superset.
//!
//! `warnings()` reports superset fields that are set but NOT translated for a
//! given target, so the tool never silently drops configuration.
//!
//! These functions are pure: they read a parsed `agent.Agent` (+ a prompt
//! string and, for pi, resolved tools/skill dirs) and produce bytes/argv.

const std = @import("std");
const agent_schema = @import("agent");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Array = std.json.Array;
const Agent = agent_schema.Agent;

/// The runtimes mc can emit native config for.
/// - `claude_code`  — Anthropic Claude Code (.claude/ subagent + settings + .mcp.json)
/// - `managed`      — Anthropic Managed Agents API (agents.create body)
/// - `openclaw`, `hermes`, `pi`
/// - `google`       — Google AX (Agent eXecutor) ax.yaml
pub const Target = enum { claude_code, managed, openclaw, hermes, pi, google };

pub fn parseTarget(name: []const u8) ?Target {
    const eq = std.mem.eql;
    if (eq(u8, name, "claude") or eq(u8, name, "claude-code")) return .claude_code;
    if (eq(u8, name, "managed") or eq(u8, name, "claude-managed") or eq(u8, name, "managed-agents")) return .managed;
    if (eq(u8, name, "openclaw")) return .openclaw;
    if (eq(u8, name, "hermes")) return .hermes;
    if (eq(u8, name, "pi")) return .pi;
    if (eq(u8, name, "google") or eq(u8, name, "ax")) return .google;
    return null;
}

const HERMES_BACKENDS = [_][]const u8{ "local", "ssh", "docker", "singularity", "modal", "daytona" };

// ---------------------------------------------------------------------------
// Claude Managed Agents — POST /v1/agents request body.
// ---------------------------------------------------------------------------

/// Build the `agents.create` request body for Anthropic's Managed Agents API.
/// `prompt_text` is the resolved system prompt (used when `agent.system` is
/// absent). Returns pretty-printed JSON owned by `allocator`.
pub fn emitManaged(allocator: std.mem.Allocator, agent: Agent, prompt_text: []const u8) ![]u8 {
    var obj = ObjectMap.init(allocator);

    try obj.put("name", .{ .string = agent.name });

    // model: string, or { id, speed } when a speed mode is requested.
    if (agent.speed) |sp| {
        var m = ObjectMap.init(allocator);
        try m.put("id", .{ .string = agent.model });
        try m.put("speed", .{ .string = sp });
        try obj.put("model", .{ .object = m });
    } else {
        try obj.put("model", .{ .string = agent.model });
    }

    const sys = agent.system orelse prompt_text;
    if (sys.len > 0) try obj.put("system", .{ .string = sys });
    if (agent.description.len > 0) try obj.put("description", .{ .string = agent.description });

    // MCP server definitions → Claude `mcp_servers` (URL connectors only).
    const defs = mcpServersMap(agent);
    if (defs) |m| {
        var servers = Array.init(allocator);
        const names = try sortedKeys(allocator, m);
        for (names) |name| {
            const dv = m.get(name).?;
            if (dv != .object) continue;
            const d = dv.object;
            if (d.get("url") == null) continue; // stdio servers handled in warnings()
            var entry = ObjectMap.init(allocator);
            var dit = d.iterator();
            while (dit.next()) |de| {
                const dk = de.key_ptr.*;
                // Drop stdio-only keys; Claude MCP connectors are URL-based.
                if (eqAny(dk, &.{ "command", "args", "env" })) continue;
                try entry.put(dk, de.value_ptr.*);
            }
            try entry.put("name", .{ .string = name });
            if (entry.get("type") == null) try entry.put("type", .{ .string = "url" });
            try servers.append(.{ .object = entry });
        }
        if (servers.items.len > 0) try obj.put("mcp_servers", .{ .array = servers });
    }

    // tools: the prebuilt agent toolset (carrying the permission policy) +
    // one mcp_toolset entry per attached MCP server.
    var tools = Array.init(allocator);
    {
        var t0 = ObjectMap.init(allocator);
        try t0.put("type", .{ .string = "agent_toolset_20260401" });
        if (agent.permissions) |p| if (p.default) |def| {
            var pol = ObjectMap.init(allocator);
            try pol.put("type", .{ .string = def });
            var dc = ObjectMap.init(allocator);
            try dc.put("permission_policy", .{ .object = pol });
            try t0.put("default_config", .{ .object = dc });
        };
        try tools.append(.{ .object = t0 });

        for (try attachList(allocator, agent, defs)) |srv| {
            var tm = ObjectMap.init(allocator);
            try tm.put("type", .{ .string = "mcp_toolset" });
            try tm.put("mcp_server_name", .{ .string = srv });
            try tools.append(.{ .object = tm });
        }
    }
    try obj.put("tools", .{ .array = tools });

    if (agent.capabilities.skills.len > 0)
        try obj.put("skills", try stringArray(allocator, agent.capabilities.skills));

    if (agent.multiagent) |ma| if (ma.delegates.len > 0) {
        var mo = ObjectMap.init(allocator);
        try mo.put("agents", try stringArray(allocator, ma.delegates));
        try obj.put("multiagent", .{ .object = mo });
    };

    if (agent.metadata) |md| try obj.put("metadata", md);

    try applyTarget(allocator, &obj, agent, "managed");
    return std.json.Stringify.valueAlloc(allocator, Value{ .object = obj }, .{ .whitespace = .indent_2 });
}

// ---------------------------------------------------------------------------
// Anthropic Claude Code — a `.claude/agents/<name>.md` subagent definition.
// ---------------------------------------------------------------------------

/// Emit a Claude Code subagent file: YAML frontmatter (name, description,
/// model, tools) + the system prompt as the markdown body. This is the unit
/// Claude Code loads from `.claude/agents/`. `--out` also writes settings.json
/// and .mcp.json (see the CLI). `prompt_text` is the system-prompt fallback.
pub fn emitClaudeCode(allocator: std.mem.Allocator, agent: Agent, prompt_text: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, "---\n");
    try buf.print(allocator, "name: {s}\n", .{agent.name});
    if (agent.description.len > 0) try buf.print(allocator, "description: {s}\n", .{agent.description});
    try buf.print(allocator, "model: {s}\n", .{claudeCodeModel(agent)});
    // tools: an explicit allowlist if the agent narrows them; otherwise omit
    // (Claude Code then grants the subagent all tools).
    if (agent.tools) |t| if (t.allow.len > 0) {
        try buf.appendSlice(allocator, "tools: ");
        for (t.allow, 0..) |tool, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, tool);
        }
        try buf.append(allocator, '\n');
    };
    try buf.appendSlice(allocator, "---\n\n");

    const sys = agent.system orelse prompt_text;
    try buf.appendSlice(allocator, sys);
    if (sys.len == 0 or sys[sys.len - 1] != '\n') try buf.append(allocator, '\n');
    return buf.toOwnedSlice(allocator);
}

/// Claude Code accepts a model alias (sonnet/opus/haiku/inherit) or a full id.
/// Map common Anthropic model ids to their alias; pass anything else through.
fn claudeCodeModel(agent: Agent) []const u8 {
    const m = agent.model;
    if (std.mem.indexOf(u8, m, "opus") != null) return "opus";
    if (std.mem.indexOf(u8, m, "sonnet") != null) return "sonnet";
    if (std.mem.indexOf(u8, m, "haiku") != null) return "haiku";
    return m;
}

/// Claude Code `.claude/settings.json`: model + permissions + env. Used by the
/// `--out` materialize path.
pub fn emitClaudeSettings(allocator: std.mem.Allocator, agent: Agent) ![]u8 {
    var o = ObjectMap.init(allocator);
    try o.put("model", .{ .string = claudeCodeModel(agent) });

    if (agent.permissions) |p| {
        var perm = ObjectMap.init(allocator);
        if (agent.tools) |t| {
            if (t.allow.len > 0) try perm.put("allow", try stringArray(allocator, t.allow));
            if (t.deny.len > 0) try perm.put("deny", try stringArray(allocator, t.deny));
        }
        if (p.default) |d| {
            // Claude Code default permission mode: map allow→bypass-ish? Keep the
            // raw value under defaultMode for the operator to refine.
            try perm.put("defaultMode", .{ .string = d });
        }
        try o.put("permissions", .{ .object = perm });
    } else if (agent.tools) |t| {
        var perm = ObjectMap.init(allocator);
        if (t.allow.len > 0) try perm.put("allow", try stringArray(allocator, t.allow));
        if (t.deny.len > 0) try perm.put("deny", try stringArray(allocator, t.deny));
        try o.put("permissions", .{ .object = perm });
    }

    if (agent.env.vars) |v| if (v == .object) try o.put("env", v);

    try applyTarget(allocator, &o, agent, "claude");
    return std.json.Stringify.valueAlloc(allocator, Value{ .object = o }, .{ .whitespace = .indent_2 });
}

/// `.mcp.json` (Claude Code / standard MCP shape) from `mcp_servers`.
/// Returns null when the agent declares no MCP servers.
pub fn emitMcpJson(allocator: std.mem.Allocator, agent: Agent) !?[]u8 {
    const defs = mcpServersMap(agent) orelse return null;
    var servers = ObjectMap.init(allocator);
    const names = try sortedKeys(allocator, defs);
    for (names) |name| {
        const dv = defs.get(name).?;
        if (dv == .object) try servers.put(name, dv);
    }
    var root = ObjectMap.init(allocator);
    try root.put("mcpServers", .{ .object = servers });
    return try std.json.Stringify.valueAlloc(allocator, Value{ .object = root }, .{ .whitespace = .indent_2 });
}

// ---------------------------------------------------------------------------
// Google AX (Agent eXecutor) — an `ax.yaml` fragment.
// ---------------------------------------------------------------------------

/// Build a **complete, valid** AX `ax.yaml`: server + eventlog (required by
/// AX's own config.Validate) plus the gemini planner (model + system prompt +
/// sampling) that runs this agent. AX agent *logic* (tools) is Python
/// (google.adk) and registry.remote_agents (needs a live address) are out of
/// scope for static config — add them via `targets.google`.
pub fn emitGoogleAx(allocator: std.mem.Allocator, agent: Agent, prompt_text: []const u8) ![]u8 {
    var gemini = ObjectMap.init(allocator);
    try gemini.put("model", .{ .string = agent.model });
    const sys = agent.system orelse prompt_text;
    if (sys.len > 0) try gemini.put("system_prompt", .{ .string = sys });
    if (agent.temperature) |t| try gemini.put("temperature", .{ .float = t });
    if (agent.max_tokens) |mt| try gemini.put("max_tokens", .{ .integer = mt });

    var planner = ObjectMap.init(allocator);
    try planner.put("type", .{ .string = "gemini" });
    try planner.put("gemini", .{ .object = gemini });

    // Required by AX's config.Validate() — emit working defaults.
    var server = ObjectMap.init(allocator);
    try server.put("address", .{ .string = ":8494" });
    var sqlite = ObjectMap.init(allocator);
    try sqlite.put("filename", .{ .string = "eventlog/log.sqlite" });
    var eventlog = ObjectMap.init(allocator);
    try eventlog.put("sqlite", .{ .object = sqlite });

    var root = ObjectMap.init(allocator);
    try root.put("server", .{ .object = server });
    try root.put("eventlog", .{ .object = eventlog });
    try root.put("planner", .{ .object = planner });

    try applyTarget(allocator, &root, agent, "google");

    var buf: std.ArrayList(u8) = .empty;
    try writeBlockObject(&buf, allocator, root, 0);
    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// OpenClaw — an `agents.list[]` entry.
// ---------------------------------------------------------------------------

pub fn emitOpenclaw(allocator: std.mem.Allocator, agent: Agent, prompt_text: []const u8) ![]u8 {
    var obj = ObjectMap.init(allocator);

    try obj.put("id", .{ .string = agent.name });
    try obj.put("name", .{ .string = agent.name });
    if (agent.description.len > 0) try obj.put("description", .{ .string = agent.description });
    try obj.put("model", .{ .string = agent.model });

    const sys = agent.system orelse prompt_text;
    if (sys.len > 0) try obj.put("systemPromptOverride", .{ .string = sys });

    // thinking levels line up with OpenClaw's thinkingDefault enum.
    try obj.put("thinkingDefault", .{ .string = agent.thinking });
    if (agent.speed) |sp| try obj.put("fastModeDefault", .{ .bool = std.mem.eql(u8, sp, "fast") });
    if (agent.context_window) |c| try obj.put("contextTokens", .{ .integer = c });

    // Sampling knobs ride OpenClaw's free-form provider `params` record.
    if (agent.max_tokens != null or agent.temperature != null) {
        var params = ObjectMap.init(allocator);
        if (agent.max_tokens) |mt| try params.put("max_tokens", .{ .integer = mt });
        if (agent.temperature) |t| try params.put("temperature", .{ .float = t });
        try obj.put("params", .{ .object = params });
    }

    if (agent.capabilities.skills.len > 0)
        try obj.put("skills", try stringArray(allocator, agent.capabilities.skills));

    if (agent.tools) |t| {
        var tobj = ObjectMap.init(allocator);
        if (t.allow.len > 0) try tobj.put("allow", try stringArray(allocator, t.allow));
        if (t.deny.len > 0) try tobj.put("deny", try stringArray(allocator, t.deny));
        try obj.put("tools", .{ .object = tobj });
    }

    if (agent.sandbox) |sb| if (sb.backend) |backend| {
        var so = ObjectMap.init(allocator);
        try so.put("backend", .{ .string = backend });
        if (sb.workdir) |wd| try so.put("workspaceRoot", .{ .string = wd });
        // Container image lives under sandbox.docker.image in OpenClaw.
        if (sb.image) |img| {
            var docker = ObjectMap.init(allocator);
            try docker.put("image", .{ .string = img });
            try so.put("docker", .{ .object = docker });
        }
        try obj.put("sandbox", .{ .object = so });
    };

    if (agent.multiagent) |ma| if (ma.delegates.len > 0) {
        var sub = ObjectMap.init(allocator);
        try sub.put("allowAgents", try stringArray(allocator, ma.delegates));
        try obj.put("subagents", .{ .object = sub });
    };

    try applyTarget(allocator, &obj, agent, "openclaw");
    return std.json.Stringify.valueAlloc(allocator, Value{ .object = obj }, .{ .whitespace = .indent_2 });
}

// ---------------------------------------------------------------------------
// Hermes — a `config.yaml` fragment (YAML).
// ---------------------------------------------------------------------------

/// Build a Hermes `config.yaml` fragment. The config is assembled as a JSON
/// value tree (so `targets.hermes` deep-merge works identically to the JSON
/// emitters), then serialized to YAML.
pub fn emitHermes(allocator: std.mem.Allocator, agent: Agent, prompt_text: []const u8) ![]u8 {
    _ = prompt_text; // Hermes reads the system prompt from soul.md, not config.yaml.
    var obj = ObjectMap.init(allocator);

    var model = ObjectMap.init(allocator);
    try model.put("default", .{ .string = agent.model });
    try model.put("provider", .{ .string = agent.provider });
    if (agent.max_tokens) |mt| try model.put("max_tokens", .{ .integer = mt });
    if (agent.context_window) |cw| try model.put("context_length", .{ .integer = cw });
    if (agent.base_url) |bu| try model.put("base_url", .{ .string = bu });
    try obj.put("model", .{ .object = model });

    var ag = ObjectMap.init(allocator);
    try ag.put("reasoning_effort", .{ .string = agent.thinking });
    // agent.max_turns: tool-calling iteration budget per turn (config.py:510).
    if (agent.max_turns) |mt| try ag.put("max_turns", .{ .integer = mt });
    try obj.put("agent", .{ .object = ag });

    // Hermes mcp_servers shape (command/args/env or url/headers) matches ours.
    if (agent.mcp_servers) |m| try obj.put("mcp_servers", m);

    if (agent.sandbox) |sb| if (sb.backend) |backend| {
        if (eqAny(backend, &HERMES_BACKENDS)) {
            var term = ObjectMap.init(allocator);
            try term.put("backend", .{ .string = backend });
            if (sb.image) |img| try term.put("docker_image", .{ .string = img });
            try obj.put("terminal", .{ .object = term });
        }
    };

    if (agent.memory) |mem| if (mem.enabled) |en| {
        var mo = ObjectMap.init(allocator);
        try mo.put("memory_enabled", .{ .bool = en });
        try obj.put("memory", .{ .object = mo });
    };

    try applyTarget(allocator, &obj, agent, "hermes");

    var buf: std.ArrayList(u8) = .empty;
    try writeBlockObject(&buf, allocator, obj, 0);
    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Pi — the `pi …` command line.
// ---------------------------------------------------------------------------

/// Build the `pi` argv. `tools` is the resolved tool-ID list (joined to CSV);
/// `skill_dirs` are absolute paths to materialized skill directories. Mirrors
/// the explicit, locked-down loadout `mc run` has always produced.
pub fn emitPiArgv(
    allocator: std.mem.Allocator,
    agent: Agent,
    tools: []const []const u8,
    skill_dirs: []const []const u8,
    prompt_text: []const u8,
    extra: []const []const u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;

    try list.append(allocator, "pi");
    try list.append(allocator, "-p");
    try list.append(allocator, prompt_text);

    if (agent.system) |sys| {
        try list.append(allocator, "--system-prompt");
        try list.append(allocator, sys);
    }

    try list.append(allocator, "--provider");
    try list.append(allocator, agent.provider);
    try list.append(allocator, "--model");
    try list.append(allocator, agent.model);
    try list.append(allocator, "--thinking");
    try list.append(allocator, agent.thinking);

    if (agent.max_tokens) |mt| {
        try list.append(allocator, "--max-tokens");
        try list.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{mt}));
    }

    try list.append(allocator, "--tools");
    try list.append(allocator, try joinCSV(allocator, tools));

    // Explicit loadout: never auto-load other skills/extensions.
    try list.append(allocator, "--no-skills");
    try list.append(allocator, "--no-extensions");
    if (agent.tools) |t| if (t.builtin) |b| if (!b) {
        try list.append(allocator, "--no-builtin-tools");
    };

    for (skill_dirs) |dir| {
        try list.append(allocator, "--skill");
        try list.append(allocator, dir);
    }

    for (extra) |e| try list.append(allocator, e);

    return list.toOwnedSlice(allocator);
}

/// Build a pi `~/.pi/agent/models.json` that defines `agent.provider` with the
/// **exact** `agent.model` id, so pi doesn't fuzzy-match the wrong variant or
/// collide with a built-in provider name. `api_key` is embedded only when
/// non-null (the materialize path injects it from `api_key_env`); pass null to
/// keep the secret out of shareable output.
pub fn emitPiModels(allocator: std.mem.Allocator, agent: Agent, api_key: ?[]const u8) ![]u8 {
    var model = ObjectMap.init(allocator);
    try model.put("id", .{ .string = agent.model });
    try model.put("name", .{ .string = agent.model });
    if (agent.reasoning) |r| try model.put("reasoning", .{ .bool = r });
    {
        var input = Array.init(allocator);
        try input.append(.{ .string = "text" });
        try model.put("input", .{ .array = input });
    }
    if (agent.context_window) |c| try model.put("contextWindow", .{ .integer = c });
    if (agent.max_tokens) |mt| try model.put("maxTokens", .{ .integer = mt });
    {
        var cost = ObjectMap.init(allocator);
        for ([_][]const u8{ "input", "output", "cacheRead", "cacheWrite" }) |k| try cost.put(k, .{ .integer = 0 });
        try model.put("cost", .{ .object = cost });
    }

    var models = Array.init(allocator);
    try models.append(.{ .object = model });

    var prov = ObjectMap.init(allocator);
    if (agent.base_url) |b| try prov.put("baseUrl", .{ .string = b });
    if (agent.api) |a| try prov.put("api", .{ .string = a });
    if (api_key) |k| try prov.put("apiKey", .{ .string = k });
    try prov.put("models", .{ .array = models });

    var providers = ObjectMap.init(allocator);
    try providers.put(agent.provider, .{ .object = prov });

    var root = ObjectMap.init(allocator);
    try root.put("providers", .{ .object = providers });
    try applyTarget(allocator, &root, agent, "pi");
    return std.json.Stringify.valueAlloc(allocator, Value{ .object = root }, .{ .whitespace = .indent_2 });
}

/// Build a pi `~/.pi/agent/settings.json` pinning the agent's provider, model,
/// and thinking level as defaults — so `pi` launches against the exact model
/// without any `--provider` / `--model` flags (no fuzzy resolution).
pub fn emitPiSettings(allocator: std.mem.Allocator, agent: Agent) ![]u8 {
    var o = ObjectMap.init(allocator);
    try o.put("defaultProvider", .{ .string = agent.provider });
    try o.put("defaultModel", .{ .string = agent.model });
    try o.put("defaultThinkingLevel", .{ .string = agent.thinking });
    var enabled = Array.init(allocator);
    try enabled.append(.{ .string = agent.model });
    try o.put("enabledModels", .{ .array = enabled });
    return std.json.Stringify.valueAlloc(allocator, Value{ .object = o }, .{ .whitespace = .indent_2 });
}

// ---------------------------------------------------------------------------
// Drop diagnostics — superset fields set but not translated for a target.
// ---------------------------------------------------------------------------

/// Returns human-readable warnings for fields the agent sets that the given
/// target's emitter does not represent (so users aren't surprised by silent
/// drops). Empty slice means the config maps cleanly. Owned by `allocator`.
pub fn warnings(allocator: std.mem.Allocator, agent: Agent, target: Target) ![]const []const u8 {
    var w: std.ArrayList([]const u8) = .empty;
    const sampling = agent.max_tokens != null or agent.temperature != null or agent.context_window != null;
    const creds = agent.base_url != null or agent.api_key_env != null;
    const has_mcp = agent.mcp.len > 0 or agent.mcp_servers != null;

    // max_turns (agent loop budget) maps only to Hermes' agent.max_turns; warn
    // for every other target so the field isn't silently dropped.
    if (agent.max_turns != null and target != .hermes)
        try add(&w, allocator, "max_turns has no first-class field on this target; it's only emitted to Hermes (agent.max_turns)");

    switch (target) {
        .managed => {
            if (sampling) try add(&w, allocator, "max_tokens/temperature/context_window apply per message at session level, not on the agent resource");
            if (creds) try add(&w, allocator, "base_url/api_key_env are Anthropic-managed and not part of the agent config");
            if (agent.tools != null) try add(&w, allocator, "tools.allow/deny are not translated; use the typed tools[] via targets.managed.tools");
            if (agent.sandbox != null) try add(&w, allocator, "sandbox belongs to the session environment, not the agent resource");
            if (agent.memory != null) try add(&w, allocator, "memory is configured via session memory stores, not the agent resource");
            if (agent.permissions) |p| if (p.rules != null) try add(&w, allocator, "permissions.rules (per-tool) aren't translated; only permissions.default maps to the toolset permission_policy");
            if (mcpHasStdio(agent)) try add(&w, allocator, "mcp_servers entries with 'command' (stdio) were omitted: Claude MCP connectors require a 'url'");
        },
        .claude_code => {
            if (sampling) try add(&w, allocator, "max_tokens/temperature aren't part of a Claude Code subagent; they apply per request");
            if (creds) try add(&w, allocator, "base_url/api_key_env aren't Claude Code config (auth is via the CLI / ANTHROPIC_API_KEY)");
            if (agent.multiagent != null) try add(&w, allocator, "multiagent.delegates aren't represented in one subagent file — emit each delegate as its own .claude/agents/<name>.md");
            if (agent.sandbox != null) try add(&w, allocator, "sandbox isn't a Claude Code concept; use permissions/hooks instead");
            if (agent.memory != null) try add(&w, allocator, "memory maps to CLAUDE.md / memory, not the subagent file");
        },
        .google => {
            if (!std.mem.eql(u8, agent.provider, "google") and !std.mem.eql(u8, agent.provider, "gemini"))
                try add(&w, allocator, "AX's planner is gemini-only; provider should be google/gemini and model a gemini-* id");
            if (has_mcp) try add(&w, allocator, "AX tools/MCP are Python (google.adk) code, not ax.yaml config — not emitted");
            if (agent.tools != null) try add(&w, allocator, "tools.allow/deny aren't AX config; AX tools are Python functions");
            if (agent.permissions != null) try add(&w, allocator, "permissions aren't part of ax.yaml (AX audits via its controller)");
            if (agent.multiagent != null) try add(&w, allocator, "multiagent roster isn't emitted; register each agent under registry.remote_agents");
        },
        .openclaw => {
            if (has_mcp) try add(&w, allocator, "MCP is configured at OpenClaw's top-level mcp.servers, not per-agent; use targets.openclaw or the top-level config");
            if (agent.permissions != null) try add(&w, allocator, "permissions are not auto-translated to OpenClaw (it uses tools policy / approvals)");
            if (agent.memory != null) try add(&w, allocator, "memory is not auto-translated to OpenClaw (top-level memory / agent memorySearch)");
            if (creds) try add(&w, allocator, "base_url/api_key_env are configured under OpenClaw models.providers; not auto-translated");
            if (agent.metadata != null) try add(&w, allocator, "metadata has no OpenClaw agent-entry field; not emitted");
        },
        .pi => {
            if (agent.api == null) try add(&w, allocator, "no `api` set — pi needs the wire protocol; add e.g. \"api\": \"anthropic-messages\"");
            if (agent.api_key_env) |e|
                try w.append(allocator, try std.fmt.allocPrint(allocator, "API key not embedded; inject ${s} at run time (or via pi auth)", .{e}));
            if (has_mcp) try add(&w, allocator, "MCP servers aren't part of pi's models.json");
            if (agent.multiagent != null) try add(&w, allocator, "pi has no sub-agent delegation; multiagent is not part of the model config");
            if (agent.permissions != null) try add(&w, allocator, "permissions are not part of a pi model config");
        },
        .hermes => {
            if (agent.system != null) try add(&w, allocator, "inline system prompt isn't emitted to config.yaml; Hermes reads it from soul.md");
            if (agent.capabilities.skills.len > 0) try add(&w, allocator, "skill names don't map to Hermes skills.external_dirs (which are directories)");
            if (agent.tools != null) try add(&w, allocator, "tools.allow/deny aren't translated; Hermes uses platform_toolsets / named toolsets");
            if (agent.permissions != null) try add(&w, allocator, "permissions aren't auto-translated to Hermes (it uses an approvals config)");
            if (agent.multiagent != null) try add(&w, allocator, "multiagent roster isn't translated; Hermes delegation is configured separately");
            if (agent.metadata != null) try add(&w, allocator, "metadata has no Hermes config field; not emitted");
            if (agent.sandbox) |sb| if (sb.backend) |b| {
                if (!eqAny(b, &HERMES_BACKENDS)) try add(&w, allocator, "sandbox.backend has no matching Hermes terminal backend; omitted");
            };
        },
    }
    return w.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Minimal JSON-value → YAML serializer (block mappings, flow for nested
// arrays/objects). YAML is a JSON superset, so flow style is always valid.
// ---------------------------------------------------------------------------

fn writeBlockObject(buf: *std.ArrayList(u8), a: std.mem.Allocator, obj: ObjectMap, indent: usize) !void {
    if (obj.count() == 0) {
        try indentBy(buf, a, indent);
        try buf.appendSlice(a, "{}\n");
        return;
    }
    var it = obj.iterator();
    while (it.next()) |e| {
        try indentBy(buf, a, indent);
        try writeYamlKey(buf, a, e.key_ptr.*);
        try buf.append(a, ':');
        const v = e.value_ptr.*;
        switch (v) {
            .object => |o| {
                if (o.count() == 0) {
                    try buf.appendSlice(a, " {}\n");
                } else {
                    try buf.append(a, '\n');
                    try writeBlockObject(buf, a, o, indent + 2);
                }
            },
            else => {
                try buf.append(a, ' ');
                try writeFlow(buf, a, v);
                try buf.append(a, '\n');
            },
        }
    }
}

fn writeFlow(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: Value) !void {
    switch (v) {
        .object => |o| {
            try buf.append(a, '{');
            var it = o.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try buf.appendSlice(a, ", ");
                first = false;
                try writeYamlKey(buf, a, e.key_ptr.*);
                try buf.appendSlice(a, ": ");
                try writeFlow(buf, a, e.value_ptr.*);
            }
            try buf.append(a, '}');
        },
        .array => |arr| {
            try buf.append(a, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                try writeFlow(buf, a, item);
            }
            try buf.append(a, ']');
        },
        .string => |s| try writeYamlString(buf, a, s),
        .integer => |n| try buf.print(a, "{d}", .{n}),
        .float => |f| try buf.print(a, "{d}", .{f}),
        .number_string => |s| try buf.appendSlice(a, s),
        .bool => |b| try buf.appendSlice(a, if (b) "true" else "false"),
        .null => try buf.appendSlice(a, "null"),
    }
}

fn writeYamlKey(buf: *std.ArrayList(u8), a: std.mem.Allocator, key: []const u8) !void {
    // Bare key if it is a simple identifier; else quote it.
    var simple = key.len > 0;
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
        if (!ok) simple = false;
    }
    if (simple) try buf.appendSlice(a, key) else try writeYamlString(buf, a, key);
}

fn writeYamlString(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => try buf.append(a, c),
    };
    try buf.append(a, '"');
}

fn indentBy(buf: *std.ArrayList(u8), a: std.mem.Allocator, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try buf.append(a, ' ');
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn add(w: *std.ArrayList([]const u8), allocator: std.mem.Allocator, msg: []const u8) !void {
    try w.append(allocator, msg);
}

fn mcpServersMap(agent: Agent) ?ObjectMap {
    const v = agent.mcp_servers orelse return null;
    return if (v == .object) v.object else null;
}

fn mcpHasStdio(agent: Agent) bool {
    const m = mcpServersMap(agent) orelse return false;
    var it = m.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .object) {
            const d = e.value_ptr.*.object;
            if (d.get("command") != null and d.get("url") == null) return true;
        }
    }
    return false;
}

/// The MCP server names to attach as Claude toolsets. An explicit `mcp`
/// allowlist is respected verbatim (the user may reference servers defined via
/// passthrough). Otherwise attach-all only includes servers that this emitter
/// actually emits — URL connectors — so no toolset ref dangles.
fn attachList(allocator: std.mem.Allocator, agent: Agent, defs: ?ObjectMap) ![]const []const u8 {
    if (agent.mcp.len > 0) return agent.mcp;
    const m = defs orelse return &.{};
    const all = try sortedKeys(allocator, m);
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |name| {
        const dv = m.get(name).?;
        if (dv == .object and dv.object.get("url") != null) try out.append(allocator, name);
    }
    return out.toOwnedSlice(allocator);
}

fn sortedKeys(allocator: std.mem.Allocator, map: ObjectMap) ![]const []const u8 {
    var keys = try allocator.alloc([]const u8, map.count());
    var it = map.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, strLess);
    return keys;
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn eqAny(s: []const u8, set: []const []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

fn stringArray(allocator: std.mem.Allocator, items: []const []const u8) !Value {
    var arr = Array.init(allocator);
    for (items) |s| try arr.append(.{ .string = s });
    return .{ .array = arr };
}

/// RFC 7386 JSON Merge Patch: deep-merge `patch` into `target`.
/// Objects merge recursively; arrays/scalars replace; a JSON `null` deletes.
fn mergePatch(allocator: std.mem.Allocator, target: Value, patch: Value) error{OutOfMemory}!Value {
    if (patch != .object) return patch;
    var out = if (target == .object) target.object else ObjectMap.init(allocator);
    var it = patch.object.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        const pv = e.value_ptr.*;
        if (pv == .null) {
            _ = out.orderedRemove(k);
        } else {
            const existing = out.get(k) orelse Value{ .object = ObjectMap.init(allocator) };
            try out.put(k, try mergePatch(allocator, existing, pv));
        }
    }
    return .{ .object = out };
}

/// Deep-merge `agent.targets.<runtime>` over `obj`.
fn applyTarget(allocator: std.mem.Allocator, obj: *ObjectMap, agent: Agent, runtime: []const u8) !void {
    const t = agent.targets orelse return;
    if (t != .object) return;
    const ov = t.object.get(runtime) orelse return;
    const merged = try mergePatch(allocator, Value{ .object = obj.* }, ov);
    if (merged == .object) obj.* = merged.object;
}

fn joinCSV(allocator: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    if (items.len == 0) return allocator.dupe(u8, "");
    var total: usize = 0;
    for (items) |it| total += it.len;
    total += items.len - 1;
    var buf = try allocator.alloc(u8, total);
    var p: usize = 0;
    for (items, 0..) |it, i| {
        if (i > 0) {
            buf[p] = ',';
            p += 1;
        }
        @memcpy(buf[p .. p + it.len], it);
        p += it.len;
    }
    return buf;
}
