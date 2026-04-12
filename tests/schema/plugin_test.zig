const std = @import("std");
const diag = @import("diagnostic");
const plugin = @import("plugin");

fn messagesContain(diags: *const diag.Diagnostics, needle: []const u8) bool {
    for (diags.items.items) |it| {
        if (std.mem.indexOf(u8, it.message, needle) != null) return true;
    }
    return false;
}

test "parsePluginStrict accepts plugin without compat/requires" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "minimal",
        \\  "version": "1.0.0",
        \\  "description": "Minimal"
        \\}
    ;
    const p = try plugin.parsePluginStrict(arena.allocator(), "plugin.json", src, &d);
    try std.testing.expect(p != null);
    try std.testing.expect(!d.hasErrors());
    try std.testing.expectEqualStrings("minimal", p.?.name);
    try std.testing.expect(p.?.compat == null);
    try std.testing.expect(p.?.requires == null);
}

test "parsePluginStrict accepts valid compat + requires" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "full",
        \\  "compat": {
        \\    "pluginApi": "^1.0.0",
        \\    "minMcVersion": ">=0.1.0",
        \\    "minPiVersion": "~2.3.4"
        \\  },
        \\  "requires": ["foo", "bar-baz"]
        \\}
    ;
    const p = try plugin.parsePluginStrict(arena.allocator(), "plugin.json", src, &d);
    try std.testing.expect(p != null);
    try std.testing.expect(!d.hasErrors());
    try std.testing.expectEqualStrings("^1.0.0", p.?.compat.?.pluginApi.?);
    try std.testing.expectEqual(@as(usize, 2), p.?.requires.?.len);
}

test "bad semver range in compat.pluginApi is diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "name": "x",
        \\  "compat": { "pluginApi": "nonsense" }
        \\}
    ;
    const p = try plugin.parsePluginStrict(arena.allocator(), "plugin.json", src, &d);
    try std.testing.expect(p == null);
    try std.testing.expect(messagesContain(&d, "invalid semver range"));
}

test "requires as string not array is a type mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{ "name": "x", "requires": "foo" }
    ;
    const p = try plugin.parsePluginStrict(arena.allocator(), "plugin.json", src, &d);
    try std.testing.expect(p == null);
    try std.testing.expect(messagesContain(&d, "expected array"));
}

test "existing Plugin struct still decodes via std.json" {
    // The legacy parsePlugin() path is covered by the inline test in
    // src/schema/plugin.zig. Here we just confirm the extended Plugin struct
    // still round-trips valid JSON without losing fields.
    const src =
        \\{
        \\  "name": "legacy",
        \\  "version": "2.1.0",
        \\  "description": "legacy path",
        \\  "author": { "name": "me" },
        \\  "keywords": ["a","b"]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = try std.json.parseFromSliceLeaky(plugin.Plugin, arena.allocator(), src, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    });
    try std.testing.expectEqualStrings("legacy", p.name);
    try std.testing.expectEqualStrings("2.1.0", p.version.?);
    try std.testing.expectEqualStrings("me", p.author.?.name);
}
