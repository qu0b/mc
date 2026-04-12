const std = @import("std");
const diag = @import("diagnostic");
const js = @import("json_strict");

fn diags(alloc: std.mem.Allocator) diag.Diagnostics {
    return diag.Diagnostics.init(alloc);
}

test "valid minimal input passes with no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var d = diags(std.testing.allocator);
    defer d.deinit();

    const schema = [_]js.FieldSpec{
        .{ .name = "name", .type = .string, .required = true },
    };
    const result = try js.parseStrict(arena.allocator(), "f.json", "{\"name\":\"ok\"}", &schema, &d);
    try std.testing.expect(result.value != null);
    try std.testing.expect(!d.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), d.count());
}

test "unknown top-level key is reported, value still returned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diags(std.testing.allocator);
    defer d.deinit();

    const schema = [_]js.FieldSpec{
        .{ .name = "name", .type = .string, .required = true },
    };
    const src = "{\"name\":\"a\",\"bogus\":1}";
    const result = try js.parseStrict(arena.allocator(), "f.json", src, &schema, &d);

    try std.testing.expect(result.value != null);
    try std.testing.expectEqual(@as(usize, 1), d.count());
    try std.testing.expect(std.mem.indexOf(u8, d.items.items[0].message, "unknown key 'bogus'") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.items.items[0].message, "known: name") != null);
}

test "missing required fields produce one diagnostic each" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diags(std.testing.allocator);
    defer d.deinit();

    const schema = [_]js.FieldSpec{
        .{ .name = "a", .type = .string, .required = true },
        .{ .name = "b", .type = .string, .required = true },
        .{ .name = "c", .type = .string, .required = false },
    };
    _ = try js.parseStrict(arena.allocator(), "f.json", "{}", &schema, &d);

    try std.testing.expectEqual(@as(usize, 2), d.count());
    var saw_a = false;
    var saw_b = false;
    for (d.items.items) |it| {
        if (std.mem.indexOf(u8, it.message, "'a'") != null) saw_a = true;
        if (std.mem.indexOf(u8, it.message, "'b'") != null) saw_b = true;
    }
    try std.testing.expect(saw_a and saw_b);
}

test "type mismatch: string expected, number given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diags(std.testing.allocator);
    defer d.deinit();

    const schema = [_]js.FieldSpec{
        .{ .name = "name", .type = .string },
    };
    _ = try js.parseStrict(arena.allocator(), "f.json", "{\"name\":123}", &schema, &d);

    try std.testing.expectEqual(@as(usize, 1), d.count());
    try std.testing.expect(std.mem.indexOf(u8, d.items.items[0].message, "expected string") != null);
    try std.testing.expect(std.mem.indexOf(u8, d.items.items[0].message, "got integer") != null);
    try std.testing.expectEqualStrings("name", d.items.items[0].path);
}

test "multiple errors accumulate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diags(std.testing.allocator);
    defer d.deinit();

    const schema = [_]js.FieldSpec{
        .{ .name = "a", .type = .string, .required = true },
        .{ .name = "b", .type = .integer },
    };
    _ = try js.parseStrict(arena.allocator(), "f.json", "{\"b\":\"notint\",\"extra\":true}", &schema, &d);

    // Expect: missing 'a', type mismatch on 'b', unknown 'extra' = 3 diagnostics.
    try std.testing.expectEqual(@as(usize, 3), d.count());
    try std.testing.expect(d.hasErrors());
}

test "nested object: unknown key in nested scope gets dotted path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diags(std.testing.allocator);
    defer d.deinit();

    const nested_schema = [_]js.FieldSpec{
        .{ .name = "toolset", .type = .string, .required = true },
    };
    const schema = [_]js.FieldSpec{
        .{ .name = "capabilities", .type = .object, .nested = &nested_schema },
    };
    const src = "{\"capabilities\":{\"toolset\":\"x\",\"weird\":1}}";
    _ = try js.parseStrict(arena.allocator(), "f.json", src, &schema, &d);

    try std.testing.expectEqual(@as(usize, 1), d.count());
    const m = d.items.items[0];
    try std.testing.expect(std.mem.indexOf(u8, m.message, "unknown key 'weird'") != null);
    try std.testing.expectEqualStrings("capabilities.weird", m.path);
}

test "enum mismatch lists allowed values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diags(std.testing.allocator);
    defer d.deinit();

    const allowed = [_][]const u8{ "red", "green", "blue" };
    const schema = [_]js.FieldSpec{
        .{ .name = "color", .type = .string, .enum_values = &allowed },
    };
    _ = try js.parseStrict(arena.allocator(), "f.json", "{\"color\":\"orange\"}", &schema, &d);

    try std.testing.expectEqual(@as(usize, 1), d.count());
    const m = d.items.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, m, "must be one of:") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "green") != null);
    try std.testing.expect(std.mem.indexOf(u8, m, "blue") != null);
}

test "integer accepts 42 and 42.0 but rejects 42.5" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const schema = [_]js.FieldSpec{
        .{ .name = "n", .type = .integer },
    };

    {
        var d = diags(std.testing.allocator);
        defer d.deinit();
        _ = try js.parseStrict(arena.allocator(), "f.json", "{\"n\":42}", &schema, &d);
        try std.testing.expect(!d.hasErrors());
    }
    {
        var d = diags(std.testing.allocator);
        defer d.deinit();
        _ = try js.parseStrict(arena.allocator(), "f.json", "{\"n\":42.0}", &schema, &d);
        try std.testing.expect(!d.hasErrors());
    }
    {
        var d = diags(std.testing.allocator);
        defer d.deinit();
        _ = try js.parseStrict(arena.allocator(), "f.json", "{\"n\":42.5}", &schema, &d);
        try std.testing.expectEqual(@as(usize, 1), d.count());
        try std.testing.expect(std.mem.indexOf(u8, d.items.items[0].message, "expected integer") != null);
    }
}

test "array of strings rejects non-string element with indexed path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diags(std.testing.allocator);
    defer d.deinit();

    const schema = [_]js.FieldSpec{
        .{ .name = "foo", .type = .array, .element_type = .string },
    };
    _ = try js.parseStrict(arena.allocator(), "f.json", "{\"foo\":[\"a\",\"b\",7]}", &schema, &d);

    try std.testing.expectEqual(@as(usize, 1), d.count());
    try std.testing.expectEqualStrings("foo[2]", d.items.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, d.items.items[0].message, "expected string") != null);
}

test "array of objects validates each element against nested schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diags(std.testing.allocator);
    defer d.deinit();

    const nested = [_]js.FieldSpec{
        .{ .name = "id", .type = .string, .required = true },
    };
    const schema = [_]js.FieldSpec{
        .{ .name = "items", .type = .array, .element_nested = &nested },
    };
    const src = "{\"items\":[{\"id\":\"a\"},{},{\"id\":\"c\",\"x\":1}]}";
    _ = try js.parseStrict(arena.allocator(), "f.json", src, &schema, &d);

    // items[1] missing 'id'; items[2] has unknown 'x' => 2 diagnostics.
    try std.testing.expectEqual(@as(usize, 2), d.count());
}

test "JSON syntax error returns null value with single root diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diags(std.testing.allocator);
    defer d.deinit();

    const schema = [_]js.FieldSpec{
        .{ .name = "name", .type = .string, .required = true },
    };
    const result = try js.parseStrict(arena.allocator(), "f.json", "{not json", &schema, &d);

    try std.testing.expect(result.value == null);
    try std.testing.expectEqual(@as(usize, 1), d.count());
    try std.testing.expectEqualStrings("", d.items.items[0].path);
    try std.testing.expect(std.mem.indexOf(u8, d.items.items[0].message, "JSON syntax error") != null);
}

test "custom validator invoked on matching type" {
    const V = struct {
        fn check(value: std.json.Value, dd: *diag.Diagnostics, file: []const u8, path: []const u8) anyerror!void {
            if (value == .string and std.mem.eql(u8, value.string, "bad")) {
                try dd.err(file, path, "value 'bad' rejected", .{});
            }
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diags(std.testing.allocator);
    defer d.deinit();

    const schema = [_]js.FieldSpec{
        .{ .name = "x", .type = .string, .validate = V.check },
    };
    _ = try js.parseStrict(arena.allocator(), "f.json", "{\"x\":\"bad\"}", &schema, &d);

    try std.testing.expectEqual(@as(usize, 1), d.count());
    try std.testing.expect(std.mem.indexOf(u8, d.items.items[0].message, "value 'bad' rejected") != null);
}
