const std = @import("std");
const compat = @import("iocompat");

/// Copy a local directory to a target directory.
pub fn copyDir(src_path: []const u8, dst_path: []const u8) !void {
    var src = try compat.openDirAbsolute(src_path);
    defer src.close(compat.getIo());

    compat.makeDirAbsolute(dst_path) catch {};

    var dst = try compat.openDirAbsoluteNoIter(dst_path);
    defer dst.close(compat.getIo());

    var iter = compat.iterateDir(src);
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                compat.copyFileInDir(src, entry.name, dst, entry.name) catch |e| {
                    if (e != error.PathAlreadyExists) return e;
                };
            },
            .directory => {
                var sub_src_buf: [4096]u8 = undefined;
                var sub_dst_buf: [4096]u8 = undefined;
                const sub_src = try std.fmt.bufPrint(&sub_src_buf, "{s}/{s}", .{ src_path, entry.name });
                const sub_dst = try std.fmt.bufPrint(&sub_dst_buf, "{s}/{s}", .{ dst_path, entry.name });
                try copyDir(sub_src, sub_dst);
            },
            .sym_link => {
                // Follow symlinks (same as Claude Code's behavior)
                var target_buf: [4096]u8 = undefined;
                const link_target_len = compat.readLinkInDir(src, entry.name, &target_buf) catch continue;
                const link_target = target_buf[0..link_target_len];
                compat.symLinkInDir(dst, link_target, entry.name) catch {};
            },
            else => {},
        }
    }
}

/// Resolve a relative path against a base directory.
pub fn resolvePath(allocator: std.mem.Allocator, base: []const u8, relative: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(relative)) {
        return allocator.dupe(u8, relative);
    }

    // Strip leading "./" if present
    const clean = if (std.mem.startsWith(u8, relative, "./"))
        relative[2..]
    else
        relative;

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, clean });
}

test "resolve relative path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const p1 = try resolvePath(arena.allocator(), "/base/dir", "./plugins/foo");
    try std.testing.expectEqualStrings("/base/dir/plugins/foo", p1);

    const p2 = try resolvePath(arena.allocator(), "/base/dir", "plugins/foo");
    try std.testing.expectEqualStrings("/base/dir/plugins/foo", p2);

    const p3 = try resolvePath(arena.allocator(), "/base/dir", "/absolute/path");
    try std.testing.expectEqualStrings("/absolute/path", p3);
}
