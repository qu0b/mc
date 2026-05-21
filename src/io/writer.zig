const std = @import("std");
const compat = @import("iocompat");

/// Atomically write content to a file: writes to a temp file then renames.
/// Prevents corruption from partial writes or crashes.
pub fn atomicWriteFile(dir_path: []const u8, name: []const u8, content: []const u8) !void {
    var dir = try compat.openDirAbsolute(dir_path);
    defer dir.close(compat.getIo());

    try atomicWriteDir(dir, name, content);
}

/// Atomically write content to a file within an already-opened directory.
pub fn atomicWriteDir(dir: compat.Dir, name: []const u8, content: []const u8) !void {
    // Create temp file in same directory (same filesystem for rename)
    var tmp_name_buf: [256]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_name_buf, ".{s}.tmp", .{name}) catch return error.NameTooLong;

    // Write content directly via compat
    compat.writeFileInDir(dir, tmp_name, content) catch |e| return e;

    // Atomic rename
    try compat.renameInDir(dir, tmp_name, name);
}

/// Write a JSON value to a file atomically with pretty-printing.
pub fn writeJson(dir_path: []const u8, name: []const u8, allocator: std.mem.Allocator, value: anytype) !void {
    const json_bytes = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(json_bytes);

    // Append newline
    var result = try allocator.alloc(u8, json_bytes.len + 1);
    defer allocator.free(result);
    @memcpy(result[0..json_bytes.len], json_bytes);
    result[json_bytes.len] = '\n';

    try atomicWriteFile(dir_path, name, result);
}

// Tests disabled for Zig 0.16 migration
