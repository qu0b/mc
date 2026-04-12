const std = @import("std");
const compat = @import("../io/compat.zig");
const manifest_mod = @import("manifest.zig");
const config_mod = @import("config.zig");

/// Initialize a new sandbox in the given directory.
/// Creates .mc/ with mc.json manifest.
pub fn init(allocator: std.mem.Allocator, dir_path: []const u8, name: ?[]const u8) !void {
    const mc_dir = try std.fmt.allocPrint(allocator, "{s}/.mc", .{dir_path});

    // Check if already initialized
    compat.accessAbsolute(mc_dir) catch {
        // Doesn't exist, create it
        try compat.makeDirAbsolute(mc_dir);
    };

    // Create plugins directory
    const plugins_dir = try std.fmt.allocPrint(allocator, "{s}/plugins", .{mc_dir});
    compat.makeDirAbsolute(plugins_dir) catch {};

    // Write default manifest
    try manifest_mod.writeDefaultManifest(allocator, dir_path, name);

    // Ensure global dirs exist too
    try config_mod.ensureHomeDirs(allocator);
}

/// Check if a directory is an mc sandbox (has .mc/mc.json).
pub fn isSandbox(allocator: std.mem.Allocator, dir_path: []const u8) bool {
    const path = std.fmt.allocPrint(allocator, "{s}/.mc/mc.json", .{dir_path}) catch return false;
    compat.accessAbsolute(path) catch return false;
    return true;
}

/// Get the plugins install directory for a sandbox.
pub fn getPluginsDir(allocator: std.mem.Allocator, project_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/.mc/plugins", .{project_dir});
}

/// List installed plugin directories in the sandbox.
pub fn listInstalledPlugins(allocator: std.mem.Allocator, project_dir: []const u8) ![][]const u8 {
    const plugins_dir = try getPluginsDir(allocator, project_dir);

    var dir = compat.openDirAbsolute(plugins_dir) catch return &.{};
    defer dir.close(compat.getIo());

    var names: std.ArrayList([]const u8) = .empty;
    var iter = compat.iterateDir(dir);
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    return names.toOwnedSlice(allocator);
}

// Tests disabled for Zig 0.16 migration
