const std = @import("std");
const compat = @import("iocompat");
const json_mod = @import("json");
const writer_mod = @import("../io/writer.zig");

/// Global mc configuration at ~/.mc/config.json
pub const GlobalConfig = struct {
    marketplaces: ?std.json.Value = null, // map of name -> { source, repo/url }
};

/// Known marketplace entry.
pub const MarketplaceRef = struct {
    name: []const u8,
    source_type: []const u8, // "github" or "url"
    location: []const u8, // "owner/repo" or git URL
    install_path: ?[]const u8 = null,
    last_updated: ?[]const u8 = null,
};

/// Get the mc home directory path (~/.mc/).
pub fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    const home_ptr = std.c.getenv("HOME") orelse return error.NoHomeDir;
    const home = std.mem.sliceTo(home_ptr, 0);
    return std.fmt.allocPrint(allocator, "{s}/.mc", .{home});
}

/// Get the cache directory path (~/.mc/cache/).
pub fn getCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = try getHomeDir(allocator);
    return std.fmt.allocPrint(allocator, "{s}/cache", .{home});
}

/// Get the marketplaces directory path (~/.mc/marketplaces/).
pub fn getMarketplacesDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = try getHomeDir(allocator);
    return std.fmt.allocPrint(allocator, "{s}/marketplaces", .{home});
}

/// Ensure ~/.mc/ and subdirectories exist.
pub fn ensureHomeDirs(allocator: std.mem.Allocator) !void {
    const home = try getHomeDir(allocator);
    const cache = try getCacheDir(allocator);
    const marketplaces = try getMarketplacesDir(allocator);

    for ([_][]const u8{ home, cache, marketplaces }) |dir| {
        compat.makeDirAbsolute(dir) catch {};
    }
}

/// Read the global config file. Returns defaults if not found.
pub fn readConfig(allocator: std.mem.Allocator) !GlobalConfig {
    const home = try getHomeDir(allocator);
    const path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{home});
    const result = json_mod.parseFile(GlobalConfig, allocator, path) catch {
        return GlobalConfig{};
    };
    return result.value;
}

/// List known marketplaces from the config + filesystem.
pub fn listMarketplaces(allocator: std.mem.Allocator) ![]MarketplaceRef {
    const mp_dir = try getMarketplacesDir(allocator);

    var dir = compat.openDirAbsolute(mp_dir) catch return &.{};
    defer dir.close(compat.getIo());

    var refs: std.ArrayList(MarketplaceRef) = .empty;
    var iter = compat.iterateDir(dir);
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Check if this directory has a .claude-plugin/marketplace.json
        const mp_json_path = try std.fmt.allocPrint(allocator, "{s}/{s}/.claude-plugin/marketplace.json", .{ mp_dir, entry.name });
        compat.accessAbsolute(mp_json_path) catch continue;

        try refs.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .source_type = "local",
            .location = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mp_dir, entry.name }),
            .install_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mp_dir, entry.name }),
        });
    }

    return refs.toOwnedSlice(allocator);
}

test "getHomeDir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const home = try getHomeDir(arena.allocator());
    try std.testing.expect(std.mem.endsWith(u8, home, "/.mc"));
}
