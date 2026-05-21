const std = @import("std");
const compat = @import("iocompat");
const json_mod = @import("json");
const writer_mod = @import("../io/writer.zig");
const config_mod = @import("../core/config.zig");

/// Cache index entry metadata.
pub const IndexEntry = struct {
    name: []const u8,
    marketplace: []const u8,
    version: []const u8,
    fetched_at: []const u8,
    source_type: []const u8,
};

/// Read the cache index from ~/.mc/cache-index.json.
pub fn readIndex(allocator: std.mem.Allocator) !std.json.Value {
    const home = try config_mod.getHomeDir(allocator);
    const path = try std.fmt.allocPrint(allocator, "{s}/cache-index.json", .{home});
    const result = json_mod.parseFile(std.json.Value, allocator, path) catch {
        return .{ .object = std.json.ObjectMap.init(allocator) };
    };
    return result.value;
}

/// Add an entry to the cache index.
pub fn addEntry(allocator: std.mem.Allocator, content_hash: []const u8, entry: IndexEntry) !void {
    const home = try config_mod.getHomeDir(allocator);

    // Build JSON manually for the index file
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    try buf.print(allocator, "  \"{s}\": {{\n", .{content_hash});
    try buf.print(allocator, "    \"name\": \"{s}\",\n", .{entry.name});
    try buf.print(allocator, "    \"marketplace\": \"{s}\",\n", .{entry.marketplace});
    try buf.print(allocator, "    \"version\": \"{s}\",\n", .{entry.version});
    try buf.print(allocator, "    \"fetched_at\": \"{s}\",\n", .{entry.fetched_at});
    try buf.print(allocator, "    \"source_type\": \"{s}\"\n", .{entry.source_type});
    try buf.appendSlice(allocator, "  }\n}\n");

    try writer_mod.atomicWriteFile(home, "cache-index.json", buf.items);
}
