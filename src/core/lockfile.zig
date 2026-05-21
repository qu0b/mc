const std = @import("std");
const compat = @import("iocompat");
const json_mod = @import("json");
const writer_mod = @import("../io/writer.zig");

/// mc.lock format for reproducible installs.
pub const LockFile = struct {
    version: u32 = 1,
    packages: ?std.json.Value = null, // map of "name@marketplace" -> LockedPackage
};

/// A locked package entry.
pub const LockedPackage = struct {
    name: []const u8,
    marketplace: []const u8,
    version: []const u8,
    content_hash: []const u8,
    source_type: []const u8,
    source_url: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
    git_sha: ?[]const u8 = null,
};

/// Read a lock file from the .mc/ directory.
pub fn readLockFile(allocator: std.mem.Allocator, project_dir: []const u8) !LockFile {
    const path = try std.fmt.allocPrint(allocator, "{s}/.mc/mc.lock", .{project_dir});
    const result = json_mod.parseFile(LockFile, allocator, path) catch {
        return LockFile{};
    };
    return result.value;
}

/// Get locked packages as a flat list.
pub fn getLockedPackages(allocator: std.mem.Allocator, lock: LockFile) ![]LockedPackage {
    const pkgs_val = lock.packages orelse return &.{};
    const obj = switch (pkgs_val) {
        .object => |o| o,
        else => return &.{},
    };

    var result: std.ArrayList(LockedPackage) = .empty;
    var iter = obj.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const cfg = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };

        // Parse "name@marketplace" key
        const sep = std.mem.indexOfScalar(u8, key, '@');
        const name = if (sep) |s| key[0..s] else key;
        const marketplace = if (sep) |s| key[s + 1 ..] else "unknown";

        try result.append(allocator, .{
            .name = name,
            .marketplace = marketplace,
            .version = getStr(cfg, "version") orelse "unknown",
            .content_hash = getStr(cfg, "content_hash") orelse "",
            .source_type = getStr(cfg, "source_type") orelse "unknown",
            .source_url = getStr(cfg, "source_url"),
            .source_path = getStr(cfg, "source_path"),
            .git_sha = getStr(cfg, "git_sha"),
        });
    }
    return result.toOwnedSlice(allocator);
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Write a lock file.
pub fn writeLockFile(allocator: std.mem.Allocator, project_dir: []const u8, packages: []const LockedPackage) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"version\": 1,\n  \"packages\": {");

    for (packages, 0..) |pkg, i| {
        if (i > 0) try buf.appendSlice(allocator, ",");
        try buf.print(allocator, "\n    \"{s}@{s}\": {{\n", .{ pkg.name, pkg.marketplace });
        try buf.print(allocator, "      \"version\": \"{s}\",\n", .{pkg.version});
        try buf.print(allocator, "      \"content_hash\": \"{s}\",\n", .{pkg.content_hash});
        try buf.print(allocator, "      \"source_type\": \"{s}\"", .{pkg.source_type});
        if (pkg.source_url) |u| {
            try buf.print(allocator, ",\n      \"source_url\": \"{s}\"", .{u});
        }
        if (pkg.source_path) |p| {
            try buf.print(allocator, ",\n      \"source_path\": \"{s}\"", .{p});
        }
        if (pkg.git_sha) |sha| {
            try buf.print(allocator, ",\n      \"git_sha\": \"{s}\"", .{sha});
        }
        try buf.appendSlice(allocator, "\n    }");
    }

    try buf.appendSlice(allocator, "\n  }\n}\n");

    const mc_dir = try std.fmt.allocPrint(allocator, "{s}/.mc", .{project_dir});
    try writer_mod.atomicWriteFile(mc_dir, "mc.lock", buf.items);
}

// Tests disabled for Zig 0.16 migration
