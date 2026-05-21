const std = @import("std");
const json_mod = @import("json");
const mmap_mod = @import("mmap");
const diag = @import("diagnostic");
const json_strict = @import("json_strict");
const semver = @import("semver");

/// Zero-copy representation of plugin.json (the .claude-plugin/plugin.json manifest).
pub const Plugin = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?Author = null,
    homepage: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    license: ?[]const u8 = null,
    keywords: ?[]const []const u8 = null,
    commands: ?std.json.Value = null, // string | []string
    agents: ?std.json.Value = null, // string | []string
    skills: ?std.json.Value = null, // string | []string
    hooks: ?std.json.Value = null, // string | HooksConfig
    mcpServers: ?std.json.Value = null, // string | McpServersConfig
    lspServers: ?std.json.Value = null, // string | LspServersConfig
    outputStyles: ?std.json.Value = null, // string | []string
    userConfig: ?std.json.Value = null,
    channels: ?[]const Channel = null,
    compat: ?Compat = null,
    requires: ?[]const []const u8 = null,
};

pub const Compat = struct {
    pluginApi: ?[]const u8 = null,
    minMcVersion: ?[]const u8 = null,
    minPiVersion: ?[]const u8 = null,
};

pub const Author = struct {
    name: []const u8,
    email: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const Channel = struct {
    server: []const u8,
    userConfig: ?std.json.Value = null,
};

/// Parsed plugin backed by an mmap'd file.
pub const ParsedPlugin = struct {
    value: Plugin,
    mapped: mmap_mod.MappedFile,

    pub fn deinit(self: *ParsedPlugin) void {
        self.mapped.close();
    }
};

/// Parse a plugin.json file with zero-copy semantics.
pub fn parsePlugin(allocator: std.mem.Allocator, path: []const u8) !ParsedPlugin {
    const result = try json_mod.parseFile(Plugin, allocator, path);
    return .{
        .value = result.value,
        .mapped = result.mapped,
    };
}

/// Resolve a Value that can be string or []string into a list of paths.
pub fn resolveStringOrArray(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const []const u8 {
    const val = value orelse return null;
    switch (val) {
        .string => |s| {
            const arr = try allocator.alloc([]const u8, 1);
            arr[0] = s;
            return arr;
        },
        .array => |arr| {
            var result = try allocator.alloc([]const u8, arr.items.len);
            for (arr.items, 0..) |item, i| {
                result[i] = switch (item) {
                    .string => |s| s,
                    else => return error.ExpectedString,
                };
            }
            return result;
        },
        else => return error.ExpectedStringOrArray,
    }
}

// ---- strict schema ----

fn isSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 63) return false;
    if (!(s[0] >= 'a' and s[0] <= 'z')) return false;
    for (s[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn validateSemverRange(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .string) return;
    _ = semver.parseRange(value.string) catch {
        try diags.err(
            file,
            try diags.arena.allocator().dupe(u8, path),
            "invalid semver range '{s}'",
            .{value.string},
        );
    };
}

fn validateSlugArray(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .array) return;
    for (value.array.items, 0..) |item, i| {
        if (item != .string) continue;
        if (!isSlug(item.string)) {
            const owned = try std.fmt.allocPrint(diags.arena.allocator(), "{s}[{d}]", .{ path, i });
            try diags.err(file, owned, "must match slug pattern, got '{s}'", .{item.string});
        }
    }
}

fn validateStringOrStringArray(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    switch (value) {
        .string => {},
        .array => |arr| for (arr.items, 0..) |item, i| {
            if (item != .string) {
                const owned = try std.fmt.allocPrint(diags.arena.allocator(), "{s}[{d}]", .{ path, i });
                try diags.err(file, owned, "expected string", .{});
            }
        },
        else => try diags.err(
            file,
            try diags.arena.allocator().dupe(u8, path),
            "expected string or array of strings, got {s}",
            .{@tagName(value)},
        ),
    }
}

const AUTHOR_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "name", .type = .string, .required = true },
    .{ .name = "email", .type = .string },
    .{ .name = "url", .type = .string },
};

const COMPAT_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "pluginApi", .type = .string, .validate = validateSemverRange },
    .{ .name = "minMcVersion", .type = .string, .validate = validateSemverRange },
    .{ .name = "minPiVersion", .type = .string, .validate = validateSemverRange },
};

const CHANNEL_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "server", .type = .string, .required = true },
    .{ .name = "userConfig", .type = .any },
};

pub const PLUGIN_SCHEMA: []const json_strict.FieldSpec = &[_]json_strict.FieldSpec{
    .{ .name = "name", .type = .string, .required = true },
    .{ .name = "version", .type = .string },
    .{ .name = "description", .type = .string },
    .{ .name = "author", .type = .object, .nested = &AUTHOR_SCHEMA },
    .{ .name = "homepage", .type = .string },
    .{ .name = "repository", .type = .string },
    .{ .name = "license", .type = .string },
    .{ .name = "keywords", .type = .array, .element_type = .string },
    .{ .name = "commands", .type = .any, .validate = validateStringOrStringArray },
    .{ .name = "agents", .type = .any, .validate = validateStringOrStringArray },
    .{ .name = "skills", .type = .any, .validate = validateStringOrStringArray },
    .{ .name = "hooks", .type = .any },
    .{ .name = "mcpServers", .type = .any },
    .{ .name = "lspServers", .type = .any },
    .{ .name = "outputStyles", .type = .any, .validate = validateStringOrStringArray },
    .{ .name = "userConfig", .type = .any },
    .{ .name = "channels", .type = .array, .element_nested = &CHANNEL_SCHEMA },
    .{ .name = "compat", .type = .object, .nested = &COMPAT_SCHEMA },
    .{ .name = "requires", .type = .array, .element_type = .string, .validate = validateSlugArray },
};

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getStringArrayOpt(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const []const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .array) return null;
    var out = try allocator.alloc([]const u8, v.array.items.len);
    for (v.array.items, 0..) |item, i| {
        out[i] = if (item == .string) item.string else "";
    }
    return out;
}

/// Parse plugin.json source with the strict schema + accumulate diagnostics.
/// Returns null if JSON syntax failed or any validation error was emitted.
pub fn parsePluginStrict(
    allocator: std.mem.Allocator,
    file: []const u8,
    src: []const u8,
    diags: *diag.Diagnostics,
) !?Plugin {
    const result = try json_strict.parseStrict(allocator, file, src, PLUGIN_SCHEMA, diags);
    if (result.value == null) return null;
    if (diags.hasErrors()) return null;

    const root = result.value.?.object;

    var author: ?Author = null;
    if (root.get("author")) |a| if (a == .object) {
        author = Author{
            .name = a.object.get("name").?.string,
            .email = getString(a.object, "email"),
            .url = getString(a.object, "url"),
        };
    };

    var compat: ?Compat = null;
    if (root.get("compat")) |c| if (c == .object) {
        compat = Compat{
            .pluginApi = getString(c.object, "pluginApi"),
            .minMcVersion = getString(c.object, "minMcVersion"),
            .minPiVersion = getString(c.object, "minPiVersion"),
        };
    };

    return Plugin{
        .name = root.get("name").?.string,
        .version = getString(root, "version"),
        .description = getString(root, "description"),
        .author = author,
        .homepage = getString(root, "homepage"),
        .repository = getString(root, "repository"),
        .license = getString(root, "license"),
        .keywords = try getStringArrayOpt(allocator, root, "keywords"),
        .commands = root.get("commands"),
        .agents = root.get("agents"),
        .skills = root.get("skills"),
        .hooks = root.get("hooks"),
        .mcpServers = root.get("mcpServers"),
        .lspServers = root.get("lspServers"),
        .outputStyles = root.get("outputStyles"),
        .userConfig = root.get("userConfig"),
        .channels = null, // zero-copy Channel[] parsing deferred — consumers can read raw JSON
        .compat = compat,
        .requires = try getStringArrayOpt(allocator, root, "requires"),
    };
}

test "parse plugin json" {
    const data =
        \\{
        \\  "name": "quality-review-plugin",
        \\  "description": "Adds a /quality-review skill",
        \\  "version": "1.0.0",
        \\  "author": { "name": "Test Author" },
        \\  "keywords": ["review", "quality"]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const p = try json_mod.parseSlice(Plugin, arena.allocator(), data);
    try std.testing.expectEqualStrings("quality-review-plugin", p.name);
    try std.testing.expectEqualStrings("1.0.0", p.version.?);
    try std.testing.expectEqualStrings("Test Author", p.author.?.name);
    try std.testing.expectEqual(@as(usize, 2), p.keywords.?.len);
}
