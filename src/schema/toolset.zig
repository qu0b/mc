const std = @import("std");
const diag = @import("diagnostic");
const json_strict = @import("json_strict");

pub const Toolset = struct {
    description: ?[]const u8 = null,
    tools: []const []const u8,
    includes: []const []const u8,
};

pub const ToolsetRegistry = struct {
    entries: std.StringHashMap(Toolset),

    pub fn deinit(self: *ToolsetRegistry) void {
        self.entries.deinit();
    }
};

fn isSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 63) return false;
    if (!(s[0] >= 'a' and s[0] <= 'z')) return false;
    for (s[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn validateNonEmptyString(value: std.json.Value, diags: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
    if (value != .string) return;
    if (value.string.len == 0) {
        try diags.err(file, try diags.arena.allocator().dupe(u8, path), "must be non-empty", .{});
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

const TOOLSET_ENTRY_SCHEMA = [_]json_strict.FieldSpec{
    .{ .name = "description", .type = .string, .validate = validateNonEmptyString },
    .{ .name = "tools", .type = .array, .required = true, .element_type = .string, .validate = validateNonEmptyStringArray },
    .{ .name = "includes", .type = .array, .required = true, .element_type = .string, .validate = validateSlugArray },
};

pub const TOOLSETS_SCHEMA: []const json_strict.FieldSpec = &[_]json_strict.FieldSpec{
    .{ .name = "toolsets", .type = .object, .required = true, .map_value_nested = &TOOLSET_ENTRY_SCHEMA },
};

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

pub fn parseToolsets(
    allocator: std.mem.Allocator,
    file: []const u8,
    src: []const u8,
    diags: *diag.Diagnostics,
) !?ToolsetRegistry {
    const result = try json_strict.parseStrict(allocator, file, src, TOOLSETS_SCHEMA, diags);
    if (result.value == null) return null;
    if (diags.hasErrors()) return null;

    const ts_obj = result.value.?.object.get("toolsets").?.object;
    var reg = ToolsetRegistry{ .entries = std.StringHashMap(Toolset).init(allocator) };

    var it = ts_obj.iterator();
    while (it.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value != .object) continue;
        const o = value.object;
        const ts: Toolset = .{
            .description = getString(o, "description"),
            .tools = try getStringArray(allocator, o, "tools"),
            .includes = try getStringArray(allocator, o, "includes"),
        };
        try reg.entries.put(entry.key_ptr.*, ts);
    }
    return reg;
}
