const std = @import("std");
const diag = @import("diagnostic");
const toolset = @import("toolset");

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

test "valid toolsets with 3 entries parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "read-only": {
        \\      "description": "Read-only tools",
        \\      "tools": ["Read", "Glob"],
        \\      "includes": []
        \\    },
        \\    "edit": {
        \\      "tools": ["Edit", "Write"],
        \\      "includes": ["read-only"]
        \\    },
        \\    "full": {
        \\      "tools": ["Bash"],
        \\      "includes": ["edit"]
        \\    }
        \\  }
        \\}
    ;
    var reg = (try toolset.parseToolsets(arena.allocator(), "toolsets.json", src, &d)).?;
    defer reg.deinit();
    try std.testing.expect(!d.hasErrors());
    try std.testing.expectEqual(@as(u32, 3), reg.entries.count());
    try std.testing.expect(reg.entries.contains("read-only"));
    try std.testing.expect(reg.entries.contains("edit"));
    try std.testing.expect(reg.entries.contains("full"));
}

test "entry missing tools field is diagnosed on that path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "broken": {
        \\      "includes": []
        \\    }
        \\  }
        \\}
    ;
    const result = try toolset.parseToolsets(arena.allocator(), "toolsets.json", src, &d);
    try std.testing.expect(result == null);
    try std.testing.expect(messagesContain(&d, "'tools'"));
    try std.testing.expect(pathMatches(&d, "toolsets.broken.tools"));
}

test "includes as string (not array) is a type mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "oops": {
        \\      "tools": ["Read"],
        \\      "includes": "read-only"
        \\    }
        \\  }
        \\}
    ;
    const result = try toolset.parseToolsets(arena.allocator(), "toolsets.json", src, &d);
    try std.testing.expect(result == null);
    try std.testing.expect(messagesContain(&d, "expected array"));
    try std.testing.expect(pathMatches(&d, "toolsets.oops.includes"));
}

test "missing top-level toolsets is diagnosed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    _ = try toolset.parseToolsets(arena.allocator(), "toolsets.json", "{}", &d);
    try std.testing.expect(messagesContain(&d, "'toolsets'"));
}
