const std = @import("std");
const json_mod = @import("json");
const mmap_mod = @import("mmap");

/// Zero-copy representation of .mcp.json.
pub const McpConfig = struct {
    mcpServers: ?std.json.Value = null,
};

/// Resolved MCP server definition.
pub const McpServer = struct {
    name: []const u8,
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    env: ?std.json.ObjectMap = null,
    cwd: ?[]const u8 = null,
    url: ?[]const u8 = null,
    @"type": ?[]const u8 = null,
};

/// Parse .mcp.json and extract server definitions.
pub fn parseMcpConfig(allocator: std.mem.Allocator, path: []const u8) !struct { servers: []McpServer, mapped: mmap_mod.MappedFile } {
    const result = try json_mod.parseFile(McpConfig, allocator, path);
    const servers = try extractServers(allocator, result.value);
    return .{ .servers = servers, .mapped = result.mapped };
}

/// Extract server definitions from a parsed McpConfig.
pub fn extractServers(allocator: std.mem.Allocator, config: McpConfig) ![]McpServer {
    const servers_val = config.mcpServers orelse return &.{};
    return extractServersFromValue(allocator, servers_val);
}

/// Extract servers from a Value that's a map of server-name -> config.
pub fn extractServersFromValue(allocator: std.mem.Allocator, value: std.json.Value) ![]McpServer {
    const obj = switch (value) {
        .object => |o| o,
        else => return &.{},
    };

    var servers: std.ArrayList(McpServer) = .empty;
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const cfg = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };

        var args_list: ?[]const []const u8 = null;
        if (cfg.get("args")) |args_val| {
            if (args_val == .array) {
                var arr: std.ArrayList([]const u8) = .empty;
                for (args_val.array.items) |item| {
                    if (item == .string) try arr.append(allocator, item.string);
                }
                args_list = try arr.toOwnedSlice(allocator);
            }
        }

        var env_map: ?std.json.ObjectMap = null;
        if (cfg.get("env")) |env_val| {
            if (env_val == .object) env_map = env_val.object;
        }

        try servers.append(allocator, .{
            .name = name,
            .command = getStr(cfg, "command"),
            .args = args_list,
            .env = env_map,
            .cwd = getStr(cfg, "cwd"),
            .url = getStr(cfg, "url"),
            .@"type" = getStr(cfg, "type"),
        });
    }

    return servers.toOwnedSlice(allocator);
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Expand ${CLAUDE_PLUGIN_ROOT} and ${CLAUDE_PLUGIN_DATA} in a string.
pub fn expandTemplateVars(allocator: std.mem.Allocator, input: []const u8, plugin_root: []const u8, plugin_data: ?[]const u8) ![]const u8 {
    var result = input;

    if (std.mem.indexOf(u8, result, "${CLAUDE_PLUGIN_ROOT}") != null) {
        result = try replaceAll(allocator, result, "${CLAUDE_PLUGIN_ROOT}", plugin_root);
    }

    if (plugin_data) |data_path| {
        if (std.mem.indexOf(u8, result, "${CLAUDE_PLUGIN_DATA}") != null) {
            result = try replaceAll(allocator, result, "${CLAUDE_PLUGIN_DATA}", data_path);
        }
    }

    return result;
}

fn replaceAll(allocator: std.mem.Allocator, input: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (i + needle.len <= input.len and std.mem.eql(u8, input[i..][0..needle.len], needle)) {
            try buf.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try buf.append(allocator, input[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

test "parse mcp config" {
    const data =
        \\{
        \\  "mcpServers": {
        \\    "my-server": {
        \\      "command": "node",
        \\      "args": ["server.js", "--port", "3000"],
        \\      "env": { "API_KEY": "test" }
        \\    }
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config = try json_mod.parseSlice(McpConfig, arena.allocator(), data);
    const servers = try extractServers(arena.allocator(), config);
    try std.testing.expectEqual(@as(usize, 1), servers.len);
    try std.testing.expectEqualStrings("my-server", servers[0].name);
    try std.testing.expectEqualStrings("node", servers[0].command.?);
    try std.testing.expectEqual(@as(usize, 3), servers[0].args.?.len);
}

test "expand template vars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try expandTemplateVars(
        arena.allocator(),
        "${CLAUDE_PLUGIN_ROOT}/scripts/run.sh",
        "/home/user/.mc/plugins/my-plugin",
        null,
    );
    try std.testing.expectEqualStrings("/home/user/.mc/plugins/my-plugin/scripts/run.sh", result);
}
