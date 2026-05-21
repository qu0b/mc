//! Shared test fixtures helpers. Absorbs the Zig 0.16 `std.Io.Dir` API (which
//! threads an `Io` context through every call and dropped recursive `makePath`)
//! so individual test suites stay readable.

const std = @import("std");
const iocompat = @import("iocompat");

pub const Dir = std.Io.Dir;

/// Absolute path of a `std.testing.tmpDir`'s directory (owned by `allocator`).
/// `realPathFileAlloc` returns a sentinel-terminated `[:0]u8`; re-dupe into a
/// plain `[]u8` so callers can `allocator.free` it without a size mismatch.
pub fn realRoot(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const z = try tmp.dir.realPathFileAlloc(iocompat.getIo(), ".", allocator);
    defer allocator.free(z);
    return allocator.dupe(u8, z);
}

/// `mkdir -p` for a slash-separated path relative to `dir`.
pub fn mkdirs(dir: Dir, path: []const u8) !void {
    const io = iocompat.getIo();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var len: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) continue;
        if (len > 0) {
            buf[len] = '/';
            len += 1;
        }
        @memcpy(buf[len .. len + comp.len], comp);
        len += comp.len;
        dir.createDir(io, buf[0..len], .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
}

/// Write `contents` to `path` (relative to `dir`), creating parent dirs.
pub fn writeRel(dir: Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try mkdirs(dir, d);
    try dir.writeFile(iocompat.getIo(), .{ .sub_path = path, .data = contents });
}

/// Delete a file relative to `dir`.
pub fn deleteRel(dir: Dir, path: []const u8) !void {
    try dir.deleteFile(iocompat.getIo(), path);
}

/// `access` a path relative to `dir` (returns the error union for assertions).
pub fn accessRel(dir: Dir, path: []const u8) !void {
    return dir.access(iocompat.getIo(), path, .{});
}

/// Read a whole file relative to `dir` (owned by `allocator`).
pub fn readRel(allocator: std.mem.Allocator, dir: Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(iocompat.getIo(), path, allocator, .unlimited);
}
