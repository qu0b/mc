const std = @import("std");
const json_mod = @import("../io/json.zig");
const mmap_mod = @import("../io/mmap.zig");

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
