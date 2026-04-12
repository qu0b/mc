const std = @import("std");
const diag = @import("diagnostic");

test "init and deinit without leaks" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    try std.testing.expect(!d.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), d.count());
}

test "err adds an error and sets hasErrors" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    try d.err("f.json", "root", "boom {d}", .{42});

    try std.testing.expectEqual(@as(usize, 1), d.count());
    try std.testing.expect(d.hasErrors());
    try std.testing.expectEqualStrings("boom 42", d.items.items[0].message);
    try std.testing.expectEqual(diag.Severity.err, d.items.items[0].severity);
}

test "warn alone leaves hasErrors false" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    try d.warn("a.json", "x.y", "look out", .{});
    try d.warn("a.json", "x.z", "again", .{});

    try std.testing.expectEqual(@as(usize, 2), d.count());
    try std.testing.expect(!d.hasErrors());
}

test "format args stored in arena" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    try d.err("f.json", "p", "count: {d}", .{42});
    try std.testing.expectEqualStrings("count: 42", d.items.items[0].message);
}

test "render with zero diagnostics" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    var buf: std.ArrayList(u8) = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try d.render(buf.writer());
    try std.testing.expectEqualStrings("Found 0 errors, 0 warnings\n", buf.items);
}

test "render groups by file and summarizes" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    try d.err("b.json", "x", "one", .{});
    try d.err("a.json", "y", "two", .{});
    try d.warn("a.json", "z", "three", .{});

    var buf: std.ArrayList(u8) = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try d.render(buf.writer());

    // a.json must appear before b.json (sorted by file).
    const a_idx = std.mem.indexOf(u8, buf.items, "a.json").?;
    const b_idx = std.mem.indexOf(u8, buf.items, "b.json").?;
    try std.testing.expect(a_idx < b_idx);

    // Summary line — mixed severities with proper pluralization.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Found 2 errors, 1 warning\n") != null);

    // All messages present.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "three") != null);
}

test "render single error uses singular form" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    try d.err("f.json", "p", "solo", .{});

    var buf: std.ArrayList(u8) = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try d.render(buf.writer());

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Found 1 error, 0 warnings\n") != null);
}
