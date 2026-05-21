const std = @import("std");
const mmap = @import("mmap");

/// Parse a JSON file into type T with zero-copy semantics.
/// String fields in the returned struct are slices into the mmap'd buffer.
/// The MappedFile must outlive the returned value.
pub fn parseFile(T: type, allocator: std.mem.Allocator, path: []const u8) !struct { value: T, mapped: mmap.MappedFile } {
    var mapped = try mmap.MappedFile.open(path);
    errdefer mapped.close();

    const value = try parseSlice(T, allocator, mapped.bytes());
    return .{ .value = value, .mapped = mapped };
}

/// Parse a JSON byte slice into type T with zero-copy semantics.
/// Uses `parseFromSliceLeaky` with `alloc_if_needed` -- strings that don't
/// require escape decoding are returned as slices into `data` (zero-copy).
/// Escaped strings are allocated via `allocator` (arena recommended).
pub fn parseSlice(T: type, allocator: std.mem.Allocator, data: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, data, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    });
}

/// Stringify a value to JSON bytes, allocated with the given allocator.
pub fn stringify(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
}

test "parse json slice zero-copy" {
    const data =
        \\{"name":"test-plugin","version":"1.0.0"}
    ;

    const T = struct {
        name: []const u8,
        version: []const u8,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parseSlice(T, arena.allocator(), data);
    try std.testing.expectEqualStrings("test-plugin", result.name);
    try std.testing.expectEqualStrings("1.0.0", result.version);

    // Verify zero-copy: the string pointers should be within the original data slice
    const data_start = @intFromPtr(data.ptr);
    const data_end = data_start + data.len;
    const name_addr = @intFromPtr(result.name.ptr);
    try std.testing.expect(name_addr >= data_start and name_addr < data_end);
}

test "parse json with unknown fields" {
    const data =
        \\{"name":"test","extra_field":"ignored","version":"2.0"}
    ;

    const T = struct {
        name: []const u8,
        version: []const u8,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parseSlice(T, arena.allocator(), data);
    try std.testing.expectEqualStrings("test", result.name);
    try std.testing.expectEqualStrings("2.0", result.version);
}
