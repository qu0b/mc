const std = @import("std");
const diag = @import("diagnostic");
const json_strict = @import("json_strict");
const semver = @import("semver");

pub const Owner = struct {
    name: []const u8,
    email: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const Metadata = struct {
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
    pluginRoot: ?[]const u8 = null,
};

pub const LibraryPluginEntry = struct {
    name: []const u8,
    source: std.json.Value,
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
    category: ?[]const u8 = null,
    skills: ?std.json.Value = null,
    commands: ?std.json.Value = null,
    tags: ?[]const []const u8 = null,
};

pub const Library = struct {
    @"$schema": ?[]const u8 = null,
    name: []const u8,
    description: ?[]const u8 = null,
    owner: Owner,
    metadata: ?Metadata = null,
    plugins: []const LibraryPluginEntry,
};

const SOURCE_KINDS = [_][]const u8{ "github", "url", "git-subdir", "npm", "local" };

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

fn validateSlug(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .string) return;
    if (!isSlug(value.string)) {
        try diags.err(
            file,
            try diags.arena.allocator().dupe(u8, path),
            "must match slug pattern, got '{s}'",
            .{value.string},
        );
    }
}

fn validateSemver(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .string) return;
    _ = semver.parseVersion(value.string) catch {
        try diags.err(
            file,
            try diags.arena.allocator().dupe(u8, path),
            "invalid semver version '{s}'",
            .{value.string},
        );
    };
}

/// Polymorphic source: string (local path) OR object with `source` enum field.
fn validateSource(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    switch (value) {
        .string => |s| {
            if (s.len == 0) {
                try diags.err(file, try diags.arena.allocator().dupe(u8, path), "source must be non-empty", .{});
            }
        },
        .object => |obj| {
            const src_type = obj.get("source") orelse {
                try diags.err(
                    file,
                    try diags.arena.allocator().dupe(u8, path),
                    "object source requires 'source' field",
                    .{},
                );
                return;
            };
            if (src_type != .string) {
                const sub = try std.fmt.allocPrint(diags.arena.allocator(), "{s}.source", .{path});
                try diags.err(file, sub, "source type must be a string", .{});
                return;
            }
            var matched = false;
            for (SOURCE_KINDS) |k| if (std.mem.eql(u8, k, src_type.string)) {
                matched = true;
                break;
            };
            if (!matched) {
                const sub = try std.fmt.allocPrint(diags.arena.allocator(), "{s}.source", .{path});
                try diags.err(
                    file,
                    sub,
                    "unknown source type '{s}' (expected: github, url, git-subdir, npm, local)",
                    .{src_type.string},
                );
            }
        },
        else => {
            try diags.err(
                file,
                try diags.arena.allocator().dupe(u8, path),
                "source must be a string or object, got {s}",
                .{@tagName(value)},
            );
        },
    }
}

/// Accept string | array[string]. No-op on other shapes (typed as `.any`).
fn validateStringOrStringArray(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    switch (value) {
        .string => {},
        .array => |arr| {
            for (arr.items, 0..) |item, i| {
                if (item != .string) {
                    const owned = try std.fmt.allocPrint(diags.arena.allocator(), "{s}[{d}]", .{ path, i });
                    try diags.err(file, owned, "expected string", .{});
                }
            }
        },
        else => {
            try diags.err(
                file,
                try diags.arena.allocator().dupe(u8, path),
                "expected string or array of strings, got {s}",
                .{@tagName(value)},
            );
        },
    }
}

// ---- schemas ----

const OWNER_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "name", .type = .string, .required = true },
    .{ .name = "email", .type = .string },
    .{ .name = "url", .type = .string },
};

const METADATA_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "description", .type = .string },
    .{ .name = "version", .type = .string, .validate = validateSemver },
    .{ .name = "pluginRoot", .type = .string },
};

const PLUGIN_ENTRY_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "name", .type = .string, .required = true, .validate = validateSlug },
    .{ .name = "source", .type = .any, .required = true, .validate = validateSource },
    .{ .name = "description", .type = .string },
    .{ .name = "version", .type = .string, .validate = validateSemver },
    .{ .name = "category", .type = .string, .validate = validateSlug },
    .{ .name = "skills", .type = .any, .validate = validateStringOrStringArray },
    .{ .name = "commands", .type = .any, .validate = validateStringOrStringArray },
    .{ .name = "tags", .type = .array, .element_type = .string },
};

pub const LIBRARY_SCHEMA: []const json_strict.FieldSpec = &[_]json_strict.FieldSpec{
    .{ .name = "$schema", .type = .string },
    .{ .name = "name", .type = .string, .required = true, .validate = validateSlug },
    .{ .name = "description", .type = .string },
    .{ .name = "owner", .type = .object, .required = true, .nested = &OWNER_SCHEMA },
    .{ .name = "metadata", .type = .object, .nested = &METADATA_SCHEMA },
    .{ .name = "plugins", .type = .array, .required = true, .element_nested = &PLUGIN_ENTRY_SCHEMA },
};

// ---- parse ----

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

pub fn parseLibrary(
    allocator: std.mem.Allocator,
    file: []const u8,
    src: []const u8,
    diags: *diag.Diagnostics,
) !?Library {
    const result = try json_strict.parseStrict(allocator, file, src, LIBRARY_SCHEMA, diags);
    if (result.value == null) return null;
    if (diags.hasErrors()) return null;

    const root = result.value.?.object;
    const owner_obj = root.get("owner").?.object;

    const owner: Owner = .{
        .name = owner_obj.get("name").?.string,
        .email = getString(owner_obj, "email"),
        .url = getString(owner_obj, "url"),
    };

    var metadata: ?Metadata = null;
    if (root.get("metadata")) |md| if (md == .object) {
        metadata = Metadata{
            .description = getString(md.object, "description"),
            .version = getString(md.object, "version"),
            .pluginRoot = getString(md.object, "pluginRoot"),
        };
    };

    const plugins_arr = root.get("plugins").?.array;
    var plugins = try allocator.alloc(LibraryPluginEntry, plugins_arr.items.len);
    for (plugins_arr.items, 0..) |entry, i| {
        const o = entry.object;
        plugins[i] = .{
            .name = o.get("name").?.string,
            .source = o.get("source").?,
            .description = getString(o, "description"),
            .version = getString(o, "version"),
            .category = getString(o, "category"),
            .skills = o.get("skills"),
            .commands = o.get("commands"),
            .tags = try getStringArrayOpt(allocator, o, "tags"),
        };
    }

    return Library{
        .@"$schema" = getString(root, "$schema"),
        .name = root.get("name").?.string,
        .description = getString(root, "description"),
        .owner = owner,
        .metadata = metadata,
        .plugins = plugins,
    };
}
