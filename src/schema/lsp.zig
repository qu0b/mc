const std = @import("std");
const json_mod = @import("../io/json.zig");

/// Zero-copy representation of .lsp.json or inline lspServers config.
/// The top-level is a map of server-name -> LspServerConfig.
pub const LspConfig = std.json.Value;

/// Resolved LSP server definition.
pub const LspServer = struct {
    name: []const u8,
    command: []const u8,
    args: ?[]const []const u8 = null,
    extension_to_language: ?[]const ExtMapping = null,
    startup_timeout: ?u64 = null,
    shutdown_timeout: ?u64 = null,
    transport: ?[]const u8 = null,
    restart_on_crash: ?bool = null,
    max_restarts: ?u32 = null,
};

pub const ExtMapping = struct {
    extension: []const u8,
    language: []const u8,
};

/// Extract LSP server definitions from a Value (the lspServers object).
pub fn extractLspServers(allocator: std.mem.Allocator, value: std.json.Value) ![]LspServer {
    const obj = switch (value) {
        .object => |o| o,
        else => return &.{},
    };

    var servers: std.ArrayList(LspServer) = .empty;
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const cfg = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };

        var ext_mappings: ?[]const ExtMapping = null;
        if (cfg.get("extensionToLanguage")) |ext_val| {
            if (ext_val == .object) {
                var mappings: std.ArrayList(ExtMapping) = .empty;
                var ext_iter = ext_val.object.iterator();
                while (ext_iter.next()) |ext_entry| {
                    if (ext_entry.value_ptr.* == .string) {
                        try mappings.append(allocator, .{
                            .extension = ext_entry.key_ptr.*,
                            .language = ext_entry.value_ptr.string,
                        });
                    }
                }
                ext_mappings = try mappings.toOwnedSlice(allocator);
            }
        }

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

        try servers.append(allocator, .{
            .name = name,
            .command = getStr(cfg, "command") orelse continue,
            .args = args_list,
            .extension_to_language = ext_mappings,
            .startup_timeout = getInt(cfg, "startupTimeout"),
            .shutdown_timeout = getInt(cfg, "shutdownTimeout"),
            .transport = getStr(cfg, "transport"),
            .restart_on_crash = getBool(cfg, "restartOnCrash"),
            .max_restarts = if (getInt(cfg, "maxRestarts")) |v| @intCast(v) else null,
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

fn getInt(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| @intCast(i),
        else => null,
    };
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

test "extract lsp servers" {
    const data =
        \\{
        \\  "rust-analyzer": {
        \\    "command": "rust-analyzer",
        \\    "extensionToLanguage": { ".rs": "rust" }
        \\  },
        \\  "gopls": {
        \\    "command": "gopls",
        \\    "args": ["serve"],
        \\    "extensionToLanguage": { ".go": "go" },
        \\    "startupTimeout": 120000
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{
        .allocate = .alloc_if_needed,
    });
    const servers = try extractLspServers(arena.allocator(), value);
    try std.testing.expectEqual(@as(usize, 2), servers.len);
}
