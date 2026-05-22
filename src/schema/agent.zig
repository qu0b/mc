const std = @import("std");
const diag = @import("diagnostic");
const json_strict = @import("json_strict");

pub const Capabilities = struct {
    skills: []const []const u8,
    commands: []const []const u8,
    extensions: []const []const u8,
    toolset: []const u8,
};

pub const Env = struct {
    required: []const []const u8,
    optional: []const []const u8,
    /// Optional explicit name=value pairs (raw object). Null when absent.
    vars: ?std.json.Value = null,
};

pub const Session = struct {
    @"export": ?bool = null,
    r2_bucket: ?[]const u8 = null,
};

// ---- superset blocks (all optional) ----

/// Cross-runtime tool policy. `toolset` (in capabilities) names a group;
/// these refine it with explicit allow/deny lists and a builtin toggle.
pub const Tools = struct {
    allow: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
    builtin: ?bool = null,
};

/// Permission policy. `default` is the fallback action; `rules` is a raw
/// map of tool-glob -> action (kept as JSON for runtime-specific shapes).
pub const Permissions = struct {
    default: ?[]const u8 = null, // always_allow | ask | deny
    rules: ?std.json.Value = null,
};

/// Execution environment / container.
pub const Sandbox = struct {
    backend: ?[]const u8 = null, // local | docker | ssh | cloud | anthropic | modal | daytona
    image: ?[]const u8 = null,
    cpu: ?i64 = null,
    memory: ?i64 = null, // MB
    network: ?[]const u8 = null, // none | restricted | all
    workdir: ?[]const u8 = null,
};

pub const Memory = struct {
    enabled: ?bool = null,
    backend: ?[]const u8 = null,
};

pub const Multiagent = struct {
    delegates: []const []const u8 = &.{},
};

pub const Agent = struct {
    // ---- existing required core ----
    name: []const u8,
    description: []const u8,
    model: []const u8,
    provider: []const u8,
    thinking: []const u8,
    prompt: []const u8,
    capabilities: Capabilities,
    env: Env,
    session: ?Session = null,

    // ---- superset (optional) ----
    /// Default runtime emitter target. pi | claude | hermes | openclaw.
    runtime: ?[]const u8 = null,
    /// Inline system prompt (overrides the `prompt` file when emitting).
    system: ?[]const u8 = null,
    /// Model speed mode (Claude fast mode et al). standard | fast.
    speed: ?[]const u8 = null,
    max_tokens: ?i64 = null,
    temperature: ?f64 = null,
    context_window: ?i64 = null,
    /// Max tool-calling iterations per conversation turn (agent loop budget).
    max_turns: ?i64 = null,
    /// Name of the env var holding the provider API key.
    api_key_env: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    /// Wire protocol the provider speaks (pi `api`): e.g. "anthropic-messages",
    /// "openai-chat-completions". Lets emitters pin a full provider definition.
    api: ?[]const u8 = null,
    /// Whether the model supports reasoning/thinking output.
    reasoning: ?bool = null,
    /// Allowlist of MCP server names to attach. Empty → attach all of
    /// `mcp_servers`. Names without a definition are assumed defined elsewhere
    /// (installed plugins / per-target passthrough).
    mcp: []const []const u8 = &.{},
    /// MCP server *definitions*: { "<name>": { command|url, args, env, headers,
    /// type } }. Raw JSON so emitters can map each runtime's native shape.
    mcp_servers: ?std.json.Value = null,
    tools: ?Tools = null,
    permissions: ?Permissions = null,
    sandbox: ?Sandbox = null,
    memory: ?Memory = null,
    multiagent: ?Multiagent = null,
    /// Arbitrary key/value tracking data (raw).
    metadata: ?std.json.Value = null,
    /// Per-runtime raw passthrough config: { "<runtime>": { ... } }.
    targets: ?std.json.Value = null,
};

const PROVIDER_VALUES = [_][]const u8{
    // generic / current
    "openrouter", "anthropic", "openai",   "local",
    // common managed-agent providers across pi / hermes / openclaw
    "google",     "gemini",    "xai",      "groq",
    "mistral",    "deepseek",  "bedrock",  "azure",
    "nous",       "ollama",    "together", "fireworks",
    "cerebras",   "vertex",    "cohere",   "moonshot",
    "kimi",       "minimax",   "zai",
};
const THINKING_VALUES = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh" };
const RUNTIME_VALUES = [_][]const u8{ "pi", "claude", "claude-code", "managed", "claude-managed", "hermes", "openclaw", "google", "ax" };
const SPEED_VALUES = [_][]const u8{ "standard", "fast" };
const NETWORK_VALUES = [_][]const u8{ "none", "restricted", "all" };
const SANDBOX_BACKEND_VALUES = [_][]const u8{ "local", "docker", "ssh", "cloud", "anthropic", "modal", "daytona" };
const PERMISSION_VALUES = [_][]const u8{ "always_allow", "ask", "deny" };

// ---- shared validators ----

fn isSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 63) return false;
    if (!(s[0] >= 'a' and s[0] <= 'z')) return false;
    for (s[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn isEnvIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    const first = s[0];
    if (!((first >= 'A' and first <= 'Z') or first == '_')) return false;
    for (s[1..]) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn isCommandName(s: []const u8) bool {
    if (s.len < 2 or s[0] != '/') return false;
    return isSlug(s[1..]);
}

fn validateNonEmptyString(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .string) return;
    if (value.string.len == 0) {
        try diags.err(file, try diags.arena.allocator().dupe(u8, path), "must be non-empty", .{});
    }
}

fn validatePositiveInt(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    const n: i64 = switch (value) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f) @as(i64, @intFromFloat(f)) else return,
        else => return,
    };
    if (n <= 0) {
        try diags.err(
            file,
            try diags.arena.allocator().dupe(u8, path),
            "must be a positive integer, got {d}",
            .{n},
        );
    }
}

fn validateEnvIdent(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .string) return;
    if (!isEnvIdent(value.string)) {
        try diags.err(
            file,
            try diags.arena.allocator().dupe(u8, path),
            "env var must match ^[A-Z_][A-Z0-9_]*$, got '{s}'",
            .{value.string},
        );
    }
}

/// Provider names are deployment-defined registries (a pi/hermes/openclaw
/// provider can be any name the runtime configures, e.g. "local-llm"). We
/// therefore accept any lowercase slug and only *warn* when the name isn't one
/// of the built-ins below — a closed enum here wrongly rejects valid configs.
fn validateProvider(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .string) return;
    const s = value.string;
    if (!isSlug(s)) {
        try diags.err(
            file,
            try diags.arena.allocator().dupe(u8, path),
            "provider must be a lowercase slug ^[a-z][a-z0-9-]{{0,62}}$, got '{s}'",
            .{s},
        );
        return;
    }
    for (PROVIDER_VALUES) |known| if (std.mem.eql(u8, known, s)) return;
    try diags.warn(
        file,
        try diags.arena.allocator().dupe(u8, path),
        "provider '{s}' is not a built-in; ensure the runtime defines it (e.g. via `mc agent emit --target pi`)",
        .{s},
    );
}

fn validateSlug(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .string) return;
    if (!isSlug(value.string)) {
        try diags.err(
            file,
            try diags.arena.allocator().dupe(u8, path),
            "must match slug pattern ^[a-z][a-z0-9-]{{0,62}}$, got '{s}'",
            .{value.string},
        );
    }
}

fn validateSlugArray(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .array) return;
    for (value.array.items, 0..) |item, i| {
        if (item != .string) continue; // type-check handled earlier
        if (!isSlug(item.string)) {
            const owned = try std.fmt.allocPrint(
                diags.arena.allocator(),
                "{s}[{d}]",
                .{ path, i },
            );
            try diags.err(file, owned, "must match slug pattern, got '{s}'", .{item.string});
        }
    }
}

fn validateNonEmptyStringArray(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .array) return;
    for (value.array.items, 0..) |item, i| {
        if (item != .string) continue;
        if (item.string.len == 0) {
            const owned = try std.fmt.allocPrint(diags.arena.allocator(), "{s}[{d}]", .{ path, i });
            try diags.err(file, owned, "must be non-empty", .{});
        }
    }
}

fn validateCommandArray(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .array) return;
    for (value.array.items, 0..) |item, i| {
        if (item != .string) continue;
        if (!isCommandName(item.string)) {
            const owned = try std.fmt.allocPrint(
                diags.arena.allocator(),
                "{s}[{d}]",
                .{ path, i },
            );
            try diags.err(
                file,
                owned,
                "command must start with '/' followed by slug chars, got '{s}'",
                .{item.string},
            );
        }
    }
}

fn validateEnvIdentArray(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .array) return;
    for (value.array.items, 0..) |item, i| {
        if (item != .string) continue;
        if (!isEnvIdent(item.string)) {
            const owned = try std.fmt.allocPrint(
                diags.arena.allocator(),
                "{s}[{d}]",
                .{ path, i },
            );
            try diags.err(
                file,
                owned,
                "env var must match ^[A-Z_][A-Z0-9_]*$, got '{s}'",
                .{item.string},
            );
        }
    }
}

// ---- schema ----

const CAPABILITIES_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "skills", .type = .array, .required = true, .element_type = .string, .validate = validateSlugArray },
    .{ .name = "commands", .type = .array, .required = true, .element_type = .string, .validate = validateCommandArray },
    .{ .name = "extensions", .type = .array, .required = true, .element_type = .string, .validate = validateSlugArray },
    .{ .name = "toolset", .type = .string, .required = true, .validate = validateSlug },
};

const ENV_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "required", .type = .array, .required = true, .element_type = .string, .validate = validateEnvIdentArray },
    .{ .name = "optional", .type = .array, .required = true, .element_type = .string, .validate = validateEnvIdentArray },
    .{ .name = "vars", .type = .object },
};

const SESSION_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "export", .type = .boolean },
    .{ .name = "r2_bucket", .type = .string, .validate = validateNonEmptyString },
};

const TOOLS_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "allow", .type = .array, .element_type = .string, .validate = validateNonEmptyStringArray },
    .{ .name = "deny", .type = .array, .element_type = .string, .validate = validateNonEmptyStringArray },
    .{ .name = "builtin", .type = .boolean },
};

const PERMISSIONS_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "default", .type = .string, .enum_values = &PERMISSION_VALUES },
    .{ .name = "rules", .type = .object },
};

const SANDBOX_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "backend", .type = .string, .enum_values = &SANDBOX_BACKEND_VALUES },
    .{ .name = "image", .type = .string, .validate = validateNonEmptyString },
    .{ .name = "cpu", .type = .integer },
    .{ .name = "memory", .type = .integer },
    .{ .name = "network", .type = .string, .enum_values = &NETWORK_VALUES },
    .{ .name = "workdir", .type = .string, .validate = validateNonEmptyString },
};

const MEMORY_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "enabled", .type = .boolean },
    .{ .name = "backend", .type = .string, .validate = validateNonEmptyString },
};

const MULTIAGENT_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "delegates", .type = .array, .element_type = .string, .validate = validateSlugArray },
};

const MCP_SERVER_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "command", .type = .string, .validate = validateNonEmptyString },
    .{ .name = "args", .type = .array, .element_type = .string },
    .{ .name = "env", .type = .object },
    .{ .name = "url", .type = .string, .validate = validateNonEmptyString },
    .{ .name = "headers", .type = .object },
    .{ .name = "type", .type = .string, .validate = validateNonEmptyString },
    .{ .name = "timeout", .type = .integer },
    .{ .name = "connect_timeout", .type = .integer },
};

pub const AGENT_SCHEMA: []const json_strict.FieldSpec = &[_]json_strict.FieldSpec{
    .{ .name = "name", .type = .string, .required = true, .validate = validateSlug },
    .{ .name = "description", .type = .string, .required = true, .validate = validateNonEmptyString },
    .{ .name = "model", .type = .string, .required = true, .validate = validateNonEmptyString },
    .{ .name = "provider", .type = .string, .required = true, .validate = validateProvider },
    .{ .name = "thinking", .type = .string, .required = true, .enum_values = &THINKING_VALUES },
    .{ .name = "prompt", .type = .string, .required = true, .validate = validateNonEmptyString },
    .{ .name = "capabilities", .type = .object, .required = true, .nested = &CAPABILITIES_SCHEMA },
    .{ .name = "env", .type = .object, .required = true, .nested = &ENV_SCHEMA },
    .{ .name = "session", .type = .object, .nested = &SESSION_SCHEMA },

    // superset (optional)
    .{ .name = "runtime", .type = .string, .enum_values = &RUNTIME_VALUES },
    .{ .name = "system", .type = .string, .validate = validateNonEmptyString },
    .{ .name = "speed", .type = .string, .enum_values = &SPEED_VALUES },
    .{ .name = "max_tokens", .type = .integer },
    .{ .name = "temperature", .type = .number },
    .{ .name = "context_window", .type = .integer },
    .{ .name = "max_turns", .type = .integer, .validate = validatePositiveInt },
    .{ .name = "api_key_env", .type = .string, .validate = validateEnvIdent },
    .{ .name = "base_url", .type = .string, .validate = validateNonEmptyString },
    .{ .name = "api", .type = .string, .validate = validateNonEmptyString },
    .{ .name = "reasoning", .type = .boolean },
    .{ .name = "mcp", .type = .array, .element_type = .string, .validate = validateSlugArray },
    .{ .name = "mcp_servers", .type = .object, .map_value_nested = &MCP_SERVER_SCHEMA },
    .{ .name = "tools", .type = .object, .nested = &TOOLS_SCHEMA },
    .{ .name = "permissions", .type = .object, .nested = &PERMISSIONS_SCHEMA },
    .{ .name = "sandbox", .type = .object, .nested = &SANDBOX_SCHEMA },
    .{ .name = "memory", .type = .object, .nested = &MEMORY_SCHEMA },
    .{ .name = "multiagent", .type = .object, .nested = &MULTIAGENT_SCHEMA },
    .{ .name = "metadata", .type = .object },
    .{ .name = "targets", .type = .object },
};

// ---- parse ----

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f) @as(i64, @intFromFloat(f)) else null,
        else => null,
    };
}

fn getFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn getStringArray(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const v = obj.get(key) orelse return &[_][]const u8{};
    if (v != .array) return &[_][]const u8{};
    var out = try allocator.alloc([]const u8, v.array.items.len);
    for (v.array.items, 0..) |item, i| {
        out[i] = if (item == .string) item.string else "";
    }
    return out;
}

/// Parse and validate agent.json. Returns null if errors were emitted or if
/// the JSON was syntactically invalid.
pub fn parseAgent(
    allocator: std.mem.Allocator,
    file: []const u8,
    src: []const u8,
    diags: *diag.Diagnostics,
) !?Agent {
    const result = try json_strict.parseStrict(allocator, file, src, AGENT_SCHEMA, diags);
    if (result.value == null) return null;
    if (diags.hasErrors()) return null;

    const root = result.value.?.object;
    const caps_obj = root.get("capabilities").?.object;
    const env_obj = root.get("env").?.object;

    const caps: Capabilities = .{
        .skills = try getStringArray(allocator, caps_obj, "skills"),
        .commands = try getStringArray(allocator, caps_obj, "commands"),
        .extensions = try getStringArray(allocator, caps_obj, "extensions"),
        .toolset = caps_obj.get("toolset").?.string,
    };
    const env: Env = .{
        .required = try getStringArray(allocator, env_obj, "required"),
        .optional = try getStringArray(allocator, env_obj, "optional"),
        .vars = env_obj.get("vars"),
    };

    var session: ?Session = null;
    if (root.get("session")) |sess_val| {
        if (sess_val == .object) {
            const so = sess_val.object;
            var s: Session = .{};
            if (so.get("export")) |e| if (e == .bool) {
                s.@"export" = e.bool;
            };
            s.r2_bucket = getString(so, "r2_bucket");
            session = s;
        }
    }

    var tools: ?Tools = null;
    if (root.get("tools")) |tv| if (tv == .object) {
        tools = Tools{
            .allow = try getStringArray(allocator, tv.object, "allow"),
            .deny = try getStringArray(allocator, tv.object, "deny"),
            .builtin = getBool(tv.object, "builtin"),
        };
    };

    var permissions: ?Permissions = null;
    if (root.get("permissions")) |pv| if (pv == .object) {
        permissions = Permissions{
            .default = getString(pv.object, "default"),
            .rules = pv.object.get("rules"),
        };
    };

    var sandbox: ?Sandbox = null;
    if (root.get("sandbox")) |sv| if (sv == .object) {
        sandbox = Sandbox{
            .backend = getString(sv.object, "backend"),
            .image = getString(sv.object, "image"),
            .cpu = getInt(sv.object, "cpu"),
            .memory = getInt(sv.object, "memory"),
            .network = getString(sv.object, "network"),
            .workdir = getString(sv.object, "workdir"),
        };
    };

    var memory: ?Memory = null;
    if (root.get("memory")) |mv| if (mv == .object) {
        memory = Memory{
            .enabled = getBool(mv.object, "enabled"),
            .backend = getString(mv.object, "backend"),
        };
    };

    var multiagent: ?Multiagent = null;
    if (root.get("multiagent")) |mv| if (mv == .object) {
        multiagent = Multiagent{
            .delegates = try getStringArray(allocator, mv.object, "delegates"),
        };
    };

    return Agent{
        .name = root.get("name").?.string,
        .description = root.get("description").?.string,
        .model = root.get("model").?.string,
        .provider = root.get("provider").?.string,
        .thinking = root.get("thinking").?.string,
        .prompt = root.get("prompt").?.string,
        .capabilities = caps,
        .env = env,
        .session = session,
        .runtime = getString(root, "runtime"),
        .system = getString(root, "system"),
        .speed = getString(root, "speed"),
        .max_tokens = getInt(root, "max_tokens"),
        .temperature = getFloat(root, "temperature"),
        .context_window = getInt(root, "context_window"),
        .max_turns = getInt(root, "max_turns"),
        .api_key_env = getString(root, "api_key_env"),
        .base_url = getString(root, "base_url"),
        .api = getString(root, "api"),
        .reasoning = getBool(root, "reasoning"),
        .mcp = try getStringArray(allocator, root, "mcp"),
        .mcp_servers = root.get("mcp_servers"),
        .tools = tools,
        .permissions = permissions,
        .sandbox = sandbox,
        .memory = memory,
        .multiagent = multiagent,
        .metadata = root.get("metadata"),
        .targets = root.get("targets"),
    };
}

/// Resolve the effective runtime for an agent (default: pi).
pub fn effectiveRuntime(agent: Agent) []const u8 {
    return agent.runtime orelse "pi";
}
