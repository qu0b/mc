const std = @import("std");
const diag = @import("diagnostic");
const library = @import("library");

fn messagesContain(diags: *const diag.Diagnostics, needle: []const u8) bool {
    for (diags.items.items) |it| {
        if (std.mem.indexOf(u8, it.message, needle) != null) return true;
    }
    return false;
}

fn pathMatches(diags: *const diag.Diagnostics, path: []const u8) bool {
    for (diags.items.items) |it| {
        if (std.mem.eql(u8, it.path, path)) return true;
    }
    return false;
}

test "valid library with string + object source both allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "my-library",
        \\  "owner": { "name": "Me" },
        \\  "plugins": [
        \\    { "name": "local-plugin", "source": "./plugins/local-plugin", "version": "1.0.0" },
        \\    { "name": "gh-plugin", "source": { "source": "github", "repo": "x/y" } }
        \\  ]
        \\}
    ;
    const lib = try library.parseLibrary(arena.allocator(), "marketplace.json", src, &d);
    try std.testing.expect(lib != null);
    try std.testing.expect(!d.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), lib.?.plugins.len);
}

test "object source missing 'source' key is diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "lib",
        \\  "owner": { "name": "Me" },
        \\  "plugins": [
        \\    { "name": "bad", "source": { "repo": "x/y" } }
        \\  ]
        \\}
    ;
    const result = try library.parseLibrary(arena.allocator(), "marketplace.json", src, &d);
    try std.testing.expect(result == null);
    try std.testing.expect(messagesContain(&d, "requires 'source' field"));
    try std.testing.expect(pathMatches(&d, "plugins[0].source"));
}

test "object source with unknown source type is diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "lib",
        \\  "owner": { "name": "Me" },
        \\  "plugins": [
        \\    { "name": "bad", "source": { "source": "unknown" } }
        \\  ]
        \\}
    ;
    const result = try library.parseLibrary(arena.allocator(), "marketplace.json", src, &d);
    try std.testing.expect(result == null);
    try std.testing.expect(messagesContain(&d, "unknown source type 'unknown'"));
    try std.testing.expect(pathMatches(&d, "plugins[0].source.source"));
}

test "missing plugins array is diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "lib",
        \\  "owner": { "name": "Me" }
        \\}
    ;
    const result = try library.parseLibrary(arena.allocator(), "marketplace.json", src, &d);
    try std.testing.expect(result == null);
    try std.testing.expect(messagesContain(&d, "'plugins'"));
}

test "invalid semver in metadata.version is diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "lib",
        \\  "owner": { "name": "Me" },
        \\  "metadata": { "version": "not-a-version" },
        \\  "plugins": []
        \\}
    ;
    _ = try library.parseLibrary(arena.allocator(), "marketplace.json", src, &d);
    try std.testing.expect(messagesContain(&d, "invalid semver version"));
}
