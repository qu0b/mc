const std = @import("std");
const compat = @import("iocompat");

/// Download a URL to a file path.
/// NOTE: std.http.Client has changed in Zig 0.16. This is stubbed out.
pub fn download(allocator: std.mem.Allocator, url: []const u8, target_path: []const u8) !void {
    _ = allocator;
    _ = url;
    _ = target_path;
    return error.NotImplemented;
}

/// Download a URL and return the content as bytes.
/// NOTE: std.http.Client has changed in Zig 0.16. This is stubbed out.
pub fn get(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    _ = allocator;
    _ = url;
    return error.NotImplemented;
}
