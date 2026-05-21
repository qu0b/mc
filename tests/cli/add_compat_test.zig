// Integration-level tests for the add/install compat gate. The CLI
// commands themselves pull in `src/io/compat.zig` (a Zig 0.16 IO shim
// that does not build under 0.14), so we exercise the gate at its
// public contract: `core_compat.checkPluginDir` on a real fixture
// directory. The behavior is identical to what add.execute runs
// between fetching and linking.

const std = @import("std");
const diag = @import("diagnostic");
const plugin = @import("plugin");
const core_compat = @import("compat");
const iocompat = @import("iocompat");

var temp_seq: usize = 0;

fn makeTempDir(allocator: std.mem.Allocator) ![]const u8 {
    temp_seq += 1;
    const path = try std.fmt.allocPrint(
        allocator,
        "/tmp/mc-phase4-test-{d}-{d}",
        .{ iocompat.nowUnixSeconds(), temp_seq },
    );
    iocompat.deleteTreeAbsolute(path);
    try iocompat.makeDirAbsolute(path);
    return path;
}

fn writeFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, body: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(path);
    try iocompat.writeFileAtPath(path, body);
}

fn countBySeverity(diags: *const diag.Diagnostics, sev: diag.Severity) usize {
    var n: usize = 0;
    for (diags.items.items) |it| {
        if (it.severity == sev) n += 1;
    }
    return n;
}

fn existsPath(path: []const u8) bool {
    iocompat.accessAbsolute(path) catch return false;
    return true;
}

test "fixture with minMcVersion 99.0.0 — checkPluginDir fails, diagnostics emitted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plugin_dir = try makeTempDir(a);
    defer iocompat.deleteTreeAbsolute(plugin_dir);

    try writeFile(a, plugin_dir, "plugin.json",
        \\{
        \\  "name": "too-new",
        \\  "version": "1.0.0",
        \\  "compat": { "minMcVersion": ">=99.0.0" }
        \\}
    );

    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkPluginDir(a, plugin_dir, "too-new", host, &diags);
    try std.testing.expect(!ok);
    try std.testing.expect(countBySeverity(&diags, .err) >= 1);

    // Simulate add.execute's failure path: the caller unlinks the plugin
    // from the sandbox. For this test we verify the directory still
    // exists (source is caller-owned) but the check reported failure.
    try std.testing.expect(existsPath(plugin_dir));
}

test "fixture with minMcVersion 99.0.0 + --ignore-compat downgrades severity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plugin_dir = try makeTempDir(a);
    defer iocompat.deleteTreeAbsolute(plugin_dir);

    try writeFile(a, plugin_dir, "plugin.json",
        \\{
        \\  "name": "too-new",
        \\  "version": "1.0.0",
        \\  "compat": { "minMcVersion": ">=99.0.0" }
        \\}
    );

    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkPluginDir(a, plugin_dir, "too-new", host, &diags);
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 1), countBySeverity(&diags, .err));

    // Simulate --ignore-compat: downgrade then proceed.
    core_compat.downgradeErrorsToWarnings(&diags);
    try std.testing.expectEqual(@as(usize, 0), countBySeverity(&diags, .err));
    try std.testing.expectEqual(@as(usize, 1), countBySeverity(&diags, .warn));
}

test "fixture with satisfied compat block — checkPluginDir passes cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plugin_dir = try makeTempDir(a);
    defer iocompat.deleteTreeAbsolute(plugin_dir);

    try writeFile(a, plugin_dir, "plugin.json",
        \\{
        \\  "name": "fine",
        \\  "compat": {
        \\    "pluginApi": "^1.0.0",
        \\    "minMcVersion": ">=0.0.1"
        \\  }
        \\}
    );

    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkPluginDir(a, plugin_dir, "fine", host, &diags);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), diags.items.items.len);
}

test "plugin.json under .claude-plugin/ is found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plugin_dir = try makeTempDir(a);
    defer iocompat.deleteTreeAbsolute(plugin_dir);

    const cp_dir = try std.fmt.allocPrint(a, "{s}/.claude-plugin", .{plugin_dir});
    try iocompat.makeDirAbsolute(cp_dir);
    try writeFile(a, cp_dir, "plugin.json",
        \\{
        \\  "name": "nested",
        \\  "compat": { "minMcVersion": ">=99.0.0" }
        \\}
    );

    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkPluginDir(a, plugin_dir, "nested", host, &diags);
    try std.testing.expect(!ok);
    try std.testing.expect(countBySeverity(&diags, .err) >= 1);
}

test "plugin without plugin.json passes with no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plugin_dir = try makeTempDir(a);
    defer iocompat.deleteTreeAbsolute(plugin_dir);

    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkPluginDir(a, plugin_dir, "bare", host, &diags);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), diags.items.items.len);
}

test "plugin.json without compat block passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plugin_dir = try makeTempDir(a);
    defer iocompat.deleteTreeAbsolute(plugin_dir);

    try writeFile(a, plugin_dir, "plugin.json",
        \\{ "name": "no-compat", "version": "1.0.0" }
    );

    var diags = diag.Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkPluginDir(a, plugin_dir, "no-compat", host, &diags);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), diags.items.items.len);
}
