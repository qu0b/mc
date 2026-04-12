const std = @import("std");
const diag = @import("diagnostic");
const toolset = @import("toolset");
const resolver = @import("toolset_resolver");

fn messagesContain(diags: *const diag.Diagnostics, needle: []const u8) bool {
    for (diags.items.items) |it| {
        if (std.mem.indexOf(u8, it.message, needle) != null) return true;
    }
    return false;
}

fn countCyclicDiags(diags: *const diag.Diagnostics) usize {
    var n: usize = 0;
    for (diags.items.items) |it| {
        if (std.mem.indexOf(u8, it.message, "cyclic includes") != null) n += 1;
    }
    return n;
}

/// Build a registry from an inline JSON source using parseToolsets.
/// The caller is responsible for keeping `arena` alive — registry entries
/// borrow strings from the parsed JSON.
fn buildRegistry(arena: *std.heap.ArenaAllocator, src: []const u8) !toolset.ToolsetRegistry {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();
    const maybe_reg = try toolset.parseToolsets(arena.allocator(), "toolsets.json", src, &d);
    if (d.hasErrors()) return error.ParseFailed;
    return maybe_reg.?;
}

test "simple toolset with no includes returns its tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "ro": { "tools": ["Read", "Glob"], "includes": [] }
        \\  }
        \\}
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const out = try resolver.resolve(std.testing.allocator, &reg, "ro", "toolsets.json", &d);
    defer std.testing.allocator.free(out);

    try std.testing.expect(!d.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("Read", out[0]);
    try std.testing.expectEqualStrings("Glob", out[1]);
}

test "toolset with one include merges tools deduped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "ro": { "tools": ["Read", "Glob"], "includes": [] },
        \\    "rw": { "tools": ["Edit", "Read"], "includes": ["ro"] }
        \\  }
        \\}
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const out = try resolver.resolve(std.testing.allocator, &reg, "rw", "toolsets.json", &d);
    defer std.testing.allocator.free(out);

    try std.testing.expect(!d.hasErrors());
    // DFS pre-order: own tools (Edit, Read) first, then included (Read dedup, Glob).
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("Edit", out[0]);
    try std.testing.expectEqualStrings("Read", out[1]);
    try std.testing.expectEqualStrings("Glob", out[2]);
}

test "transitive chain A -> B -> C" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "c": { "tools": ["C1"], "includes": [] },
        \\    "b": { "tools": ["B1"], "includes": ["c"] },
        \\    "a": { "tools": ["A1"], "includes": ["b"] }
        \\  }
        \\}
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const out = try resolver.resolve(std.testing.allocator, &reg, "a", "toolsets.json", &d);
    defer std.testing.allocator.free(out);

    try std.testing.expect(!d.hasErrors());
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("A1", out[0]);
    try std.testing.expectEqualStrings("B1", out[1]);
    try std.testing.expectEqualStrings("C1", out[2]);
}

test "diamond A -> B,C  B -> D  C -> D yields each tool once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "d": { "tools": ["D1"], "includes": [] },
        \\    "c": { "tools": ["C1"], "includes": ["d"] },
        \\    "b": { "tools": ["B1"], "includes": ["d"] },
        \\    "a": { "tools": ["A1"], "includes": ["b", "c"] }
        \\  }
        \\}
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const out = try resolver.resolve(std.testing.allocator, &reg, "a", "toolsets.json", &d);
    defer std.testing.allocator.free(out);

    try std.testing.expect(!d.hasErrors());
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqualStrings("A1", out[0]);
    try std.testing.expectEqualStrings("B1", out[1]);
    try std.testing.expectEqualStrings("D1", out[2]);
    try std.testing.expectEqualStrings("C1", out[3]);
}

test "unknown target toolset returns UnknownToolset with diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{ "toolsets": { "ro": { "tools": ["Read"], "includes": [] } } }
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const res = resolver.resolve(std.testing.allocator, &reg, "nonexistent", "toolsets.json", &d);
    try std.testing.expectError(resolver.ResolveError.UnknownToolset, res);
    try std.testing.expectEqual(@as(usize, 1), d.count());
    try std.testing.expect(messagesContain(&d, "'nonexistent'"));
    try std.testing.expect(messagesContain(&d, "not found"));
}

test "unknown include is skipped with diagnostic, error still UnknownToolset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "a": { "tools": ["A1"], "includes": ["ghost"] }
        \\  }
        \\}
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const res = resolver.resolve(std.testing.allocator, &reg, "a", "toolsets.json", &d);
    try std.testing.expectError(resolver.ResolveError.UnknownToolset, res);
    try std.testing.expectEqual(@as(usize, 1), d.count());
    try std.testing.expect(messagesContain(&d, "'ghost'"));
}

test "self-cycle emits CyclicIncludes diagnostic + error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "a": { "tools": ["A1"], "includes": ["a"] }
        \\  }
        \\}
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const res = resolver.resolve(std.testing.allocator, &reg, "a", "toolsets.json", &d);
    try std.testing.expectError(resolver.ResolveError.CyclicIncludes, res);
    try std.testing.expect(messagesContain(&d, "cyclic includes"));
    try std.testing.expect(messagesContain(&d, "a -> a"));
}

test "mutual cycle A -> B -> A emits cycle path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "a": { "tools": ["A1"], "includes": ["b"] },
        \\    "b": { "tools": ["B1"], "includes": ["a"] }
        \\  }
        \\}
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const res = resolver.resolve(std.testing.allocator, &reg, "a", "toolsets.json", &d);
    try std.testing.expectError(resolver.ResolveError.CyclicIncludes, res);
    try std.testing.expect(messagesContain(&d, "cyclic includes"));
    try std.testing.expect(messagesContain(&d, "a -> b -> a"));
}

test "order preserves DFS first-encounter left-to-right" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "leaf": { "tools": ["L1", "L2"], "includes": [] },
        \\    "mid":  { "tools": ["M1"], "includes": ["leaf"] },
        \\    "root": { "tools": ["R1", "R2"], "includes": ["mid", "leaf"] }
        \\  }
        \\}
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const out = try resolver.resolve(std.testing.allocator, &reg, "root", "toolsets.json", &d);
    defer std.testing.allocator.free(out);

    try std.testing.expect(!d.hasErrors());
    // root own: R1, R2; recurse mid (M1); recurse leaf from mid (L1, L2);
    // then root's second include "leaf" is already visited -> skip.
    try std.testing.expectEqual(@as(usize, 5), out.len);
    try std.testing.expectEqualStrings("R1", out[0]);
    try std.testing.expectEqualStrings("R2", out[1]);
    try std.testing.expectEqualStrings("M1", out[2]);
    try std.testing.expectEqualStrings("L1", out[3]);
    try std.testing.expectEqualStrings("L2", out[4]);
}

test "resolveAll surfaces multiple independent cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{
        \\  "toolsets": {
        \\    "a": { "tools": ["A1"], "includes": ["b"] },
        \\    "b": { "tools": ["B1"], "includes": ["a"] },
        \\    "x": { "tools": ["X1"], "includes": ["y"] },
        \\    "y": { "tools": ["Y1"], "includes": ["x"] },
        \\    "clean": { "tools": ["C1"], "includes": [] }
        \\  }
        \\}
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const res = resolver.resolveAll(std.testing.allocator, &reg, "toolsets.json", &d);
    try std.testing.expectError(resolver.ResolveError.CyclicIncludes, res);
    // At least two cycle diagnostics — one per independent SCC.
    try std.testing.expect(countCyclicDiags(&d) >= 2);
}

test "empty toolset name is UnknownToolset, not special-cased" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const src =
        \\{ "toolsets": { "a": { "tools": ["A1"], "includes": [] } } }
    ;
    var reg = try buildRegistry(&arena, src);
    defer reg.deinit();

    const res = resolver.resolve(std.testing.allocator, &reg, "", "toolsets.json", &d);
    try std.testing.expectError(resolver.ResolveError.UnknownToolset, res);
    try std.testing.expectEqual(@as(usize, 1), d.count());
}
