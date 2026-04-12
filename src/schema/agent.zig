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
};

pub const Session = struct {
    @"export": ?bool = null,
    r2_bucket: ?[]const u8 = null,
};

pub const Agent = struct {
    name: []const u8,
    description: []const u8,
    model: []const u8,
    provider: []const u8,
    thinking: []const u8,
    prompt: []const u8,
    capabilities: Capabilities,
    env: Env,
    session: ?Session = null,
};

const PROVIDER_VALUES = [_][]const u8{ "openrouter", "anthropic", "openai", "local" };
const THINKING_VALUES = [_][]const u8{ "off", "minimal", "low", "medium", "high" };

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
};

const SESSION_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "export", .type = .boolean },
    .{ .name = "r2_bucket", .type = .string, .validate = validateNonEmptyString },
};

pub const AGENT_SCHEMA: []const json_strict.FieldSpec = &[_]json_strict.FieldSpec{
    .{ .name = "name", .type = .string, .required = true, .validate = validateSlug },
    .{ .name = "description", .type = .string, .required = true, .validate = validateNonEmptyString },
    .{ .name = "model", .type = .string, .required = true, .validate = validateNonEmptyString },
    .{ .name = "provider", .type = .string, .required = true, .enum_values = &PROVIDER_VALUES },
    .{ .name = "thinking", .type = .string, .required = true, .enum_values = &THINKING_VALUES },
    .{ .name = "prompt", .type = .string, .required = true, .validate = validateNonEmptyString },
    .{ .name = "capabilities", .type = .object, .required = true, .nested = &CAPABILITIES_SCHEMA },
    .{ .name = "env", .type = .object, .required = true, .nested = &ENV_SCHEMA },
    .{ .name = "session", .type = .object, .nested = &SESSION_SCHEMA },
};

// ---- parse ----

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
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
    };
}
