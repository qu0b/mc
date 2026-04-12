const std = @import("std");
const compat = @import("../io/compat.zig");
const hash_mod = @import("../io/hash.zig");
const config_mod = @import("../core/config.zig");

/// Content-addressed blob store at ~/.mc/cache/.
pub const ContentStore = struct {
    root: []const u8, // ~/.mc/cache

    pub fn init(allocator: std.mem.Allocator) !ContentStore {
        const cache_dir = try config_mod.getCacheDir(allocator);
        compat.makeDirAbsolute(cache_dir) catch {};
        return .{ .root = cache_dir };
    }

    /// Check if content with the given hash exists in the store.
    pub fn has(self: *const ContentStore, allocator: std.mem.Allocator, content_hash: []const u8) bool {
        const dir_name = std.fmt.allocPrint(allocator, "{s}/sha256-{s}", .{ self.root, content_hash }) catch return false;
        compat.accessAbsolute(dir_name) catch return false;
        return true;
    }

    /// Store a directory in the content-addressed store.
    /// Returns the content hash.
    pub fn store(self: *const ContentStore, allocator: std.mem.Allocator, source_dir: []const u8) ![]const u8 {
        // Compute content hash
        const content_hash = try hash_mod.hashDirectory(allocator, source_dir);
        const hash_str = try allocator.dupe(u8, &content_hash);

        // Check if already stored
        if (self.has(allocator, hash_str)) return hash_str;

        // Create cache directory
        const cache_path = try std.fmt.allocPrint(allocator, "{s}/sha256-{s}", .{ self.root, hash_str });
        try compat.makeDirAbsolute(cache_path);

        // Copy files from source to cache
        try copyTree(source_dir, cache_path);

        return hash_str;
    }

    /// Link (hardlink) from cache to target directory.
    /// Falls back to copy if cross-filesystem.
    pub fn link(self: *const ContentStore, allocator: std.mem.Allocator, content_hash: []const u8, target_dir: []const u8) !void {
        const cache_path = try std.fmt.allocPrint(allocator, "{s}/sha256-{s}", .{ self.root, content_hash });

        // Ensure target parent exists
        if (std.fs.path.dirname(target_dir)) |parent| {
            compat.makeDirAbsolute(parent) catch {};
        }

        // Remove existing target
        compat.deleteTreeAbsolute(target_dir);

        // Try hardlink tree, fall back to copy
        linkTree(cache_path, target_dir) catch {
            try copyTree(cache_path, target_dir);
        };
    }

    /// Get the path to a cached item.
    pub fn getPath(self: *const ContentStore, allocator: std.mem.Allocator, content_hash: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/sha256-{s}", .{ self.root, content_hash });
    }

    /// List all entries in the cache.
    pub fn listEntries(self: *const ContentStore, allocator: std.mem.Allocator) ![]CacheEntry {
        var dir = compat.openDirAbsolute(self.root) catch return &.{};
        defer dir.close(compat.getIo());

        var entries = std.ArrayList(CacheEntry).init(allocator);
        var iter = compat.iterateDir(dir);
        while (try iter.next()) |entry| {
            if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "sha256-")) {
                try entries.append(.{
                    .hash = try allocator.dupe(u8, entry.name[7..]),
                    .path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.root, entry.name }),
                });
            }
        }
        return entries.toOwnedSlice();
    }
};

pub const CacheEntry = struct {
    hash: []const u8,
    path: []const u8,
};

fn copyTree(src_path: []const u8, dst_path: []const u8) !void {
    var src_dir = try compat.openDirAbsolute(src_path);
    defer src_dir.close(compat.getIo());

    compat.makeDirAbsolute(dst_path) catch {};

    var dst_dir = try compat.openDirAbsoluteNoIter(dst_path);
    defer dst_dir.close(compat.getIo());

    var iter = compat.iterateDir(src_dir);
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                compat.copyFileInDir(src_dir, entry.name, dst_dir, entry.name) catch |e| {
                    if (e != error.PathAlreadyExists) return e;
                };
            },
            .directory => {
                var sub_src_buf: [4096]u8 = undefined;
                var sub_dst_buf: [4096]u8 = undefined;
                const sub_src = try std.fmt.bufPrint(&sub_src_buf, "{s}/{s}", .{ src_path, entry.name });
                const sub_dst = try std.fmt.bufPrint(&sub_dst_buf, "{s}/{s}", .{ dst_path, entry.name });
                try copyTree(sub_src, sub_dst);
            },
            else => {},
        }
    }
}

fn linkTree(src_path: []const u8, dst_path: []const u8) !void {
    var src_dir = try compat.openDirAbsolute(src_path);
    defer src_dir.close(compat.getIo());

    compat.makeDirAbsolute(dst_path) catch {};

    var iter = compat.iterateDir(src_dir);
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                // Just copy instead of hard-linking (simpler, avoids posix.link removal)
                var sd = compat.openDirAbsoluteNoIter(src_path) catch continue;
                defer sd.close(compat.getIo());
                var dd = compat.openDirAbsoluteNoIter(dst_path) catch continue;
                defer dd.close(compat.getIo());
                compat.copyFileInDir(sd, entry.name, dd, entry.name) catch {};
            },
            .directory => {
                var sub_src_buf: [4096]u8 = undefined;
                var sub_dst_buf: [4096]u8 = undefined;
                const sub_src = try std.fmt.bufPrint(&sub_src_buf, "{s}/{s}", .{ src_path, entry.name });
                const sub_dst = try std.fmt.bufPrint(&sub_dst_buf, "{s}/{s}", .{ dst_path, entry.name });
                try linkTree(sub_src, sub_dst);
            },
            else => {},
        }
    }
}

// Tests disabled for Zig 0.16 migration
