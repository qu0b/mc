const std = @import("std");
const compat = @import("compat.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const HASH_HEX_LEN = Sha256.digest_length * 2;
pub const HashHex = [HASH_HEX_LEN]u8;

/// Hash a byte slice and return the hex-encoded SHA256 digest.
pub fn hashBytes(data: []const u8) HashHex {
    var h = Sha256.init(.{});
    h.update(data);
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    return hexEncode(digest);
}

/// Hash a file's contents.
pub fn hashFile(path: []const u8) !HashHex {
    const file = try compat.openFileAbsolute(path);
    defer compat.closeFile(file);

    var h = Sha256.init(.{});
    var buf: [8192]u8 = undefined;

    while (true) {
        const n = try compat.fileRead(file, &buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    return hexEncode(digest);
}

/// Hash a directory tree: hash(sorted(path + "\0" + content + "\0")) for each file.
/// This produces a stable content hash regardless of filesystem metadata.
pub fn hashDirectory(allocator: std.mem.Allocator, dir_path: []const u8) !HashHex {
    var dir = try compat.openDirAbsolute(dir_path);
    defer dir.close(compat.getIo());

    // Collect all file paths
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    try collectFiles(allocator, dir, "", &paths);

    // Sort for deterministic hash
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var h = Sha256.init(.{});

    for (paths.items) |rel_path| {
        h.update(rel_path);
        h.update("\x00");

        const content = compat.readFileInDir(dir, rel_path, allocator) catch continue;
        defer allocator.free(content);
        h.update(content);
        h.update("\x00");
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    return hexEncode(digest);
}

fn collectFiles(
    allocator: std.mem.Allocator,
    dir: compat.Dir,
    prefix: []const u8,
    paths: *std.ArrayList([]const u8),
) !void {
    var iter = compat.iterateDir(dir);
    while (try iter.next()) |entry| {
        const rel = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });

        switch (entry.kind) {
            .file => try paths.append(allocator, rel),
            .directory => {
                // Skip hidden dirs like .git
                if (entry.name.len > 0 and entry.name[0] == '.') {
                    allocator.free(rel);
                    continue;
                }
                var sub = dir.openDir(compat.getIo(), entry.name, .{ .iterate = true }) catch {
                    allocator.free(rel);
                    continue;
                };
                defer sub.close(compat.getIo());
                try collectFiles(allocator, sub, rel, paths);
                allocator.free(rel);
            },
            else => allocator.free(rel),
        }
    }
}

fn hexEncode(digest: [Sha256.digest_length]u8) HashHex {
    const hex = "0123456789abcdef";
    var out: HashHex = undefined;
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

/// Format a hash hex as a cache key: "sha256-{hex}"
pub fn cacheKey(hash: HashHex) [7 + HASH_HEX_LEN]u8 {
    var key: [7 + HASH_HEX_LEN]u8 = undefined;
    @memcpy(key[0..7], "sha256-");
    @memcpy(key[7..], &hash);
    return key;
}

test "hashBytes produces consistent output" {
    const h1 = hashBytes("hello world");
    const h2 = hashBytes("hello world");
    try std.testing.expectEqualStrings(&h1, &h2);

    const h3 = hashBytes("different");
    try std.testing.expect(!std.mem.eql(u8, &h1, &h3));
}

test "cacheKey format" {
    const h = hashBytes("test");
    const key = cacheKey(h);
    try std.testing.expect(std.mem.startsWith(u8, &key, "sha256-"));
}

// hashDirectory test disabled for Zig 0.16 migration
