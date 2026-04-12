const std = @import("std");
const compat = @import("../io/compat.zig");
const json_mod = @import("../io/json.zig");
const writer_mod = @import("../io/writer.zig");

/// mc.json project manifest.
pub const Manifest = struct {
    name: ?[]const u8 = null,
    plugins: ?std.json.Value = null, // map of name -> { marketplace, version }
    marketplaces: ?std.json.Value = null, // map of name -> { source, repo/url }
};

/// A resolved plugin dependency from the manifest.
pub const PluginDep = struct {
    name: []const u8,
    marketplace: ?[]const u8,
    version: ?[]const u8,
};

/// Read a manifest from the .mc/ directory.
pub fn readManifest(allocator: std.mem.Allocator, project_dir: []const u8) !Manifest {
    const path = try std.fmt.allocPrint(allocator, "{s}/.mc/mc.json", .{project_dir});
    const result = try json_mod.parseFile(Manifest, allocator, path);
    return result.value;
}

/// Get the list of plugin dependencies from a manifest.
pub fn getPluginDeps(allocator: std.mem.Allocator, manifest: Manifest) ![]PluginDep {
    const plugins_val = manifest.plugins orelse return &.{};
    const obj = switch (plugins_val) {
        .object => |o| o,
        else => return &.{},
    };

    var deps: std.ArrayList(PluginDep) = .empty;
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const cfg = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };

        try deps.append(allocator, .{
            .name = name,
            .marketplace = getStr(cfg, "marketplace"),
            .version = getStr(cfg, "version"),
        });
    }
    return deps.toOwnedSlice(allocator);
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Write a default manifest file.
pub fn writeDefaultManifest(allocator: std.mem.Allocator, dir_path: []const u8, name: ?[]const u8) !void {
    const project_name = name orelse blk: {
        // Derive from directory name
        const real = try compat.realpathAlloc(allocator, dir_path);
        break :blk std.fs.path.basename(real);
    };

    // Build manifest JSON manually
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, "{\n");
    try buf.print(allocator, "  \"name\": \"{s}\",\n", .{project_name});
    try buf.appendSlice(allocator, "  \"plugins\": {},\n");
    try buf.appendSlice(allocator, "  \"marketplaces\": {}\n");
    try buf.appendSlice(allocator, "}\n");

    const mc_dir = try std.fmt.allocPrint(allocator, "{s}/.mc", .{dir_path});
    compat.makeDirAbsolute(mc_dir) catch {};

    try writer_mod.atomicWriteFile(mc_dir, "mc.json", buf.items);
}

// Tests disabled for Zig 0.16 migration
