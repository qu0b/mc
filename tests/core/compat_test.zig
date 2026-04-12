const std = @import("std");
const diag = @import("diagnostic");
const plugin = @import("plugin");
const core_compat = @import("compat");

fn findMessage(diags: *const diag.Diagnostics, needle: []const u8) ?*const diag.Diagnostic {
    for (diags.items.items) |*it| {
        if (std.mem.indexOf(u8, it.message, needle) != null) return it;
    }
    return null;
}

fn countBySeverity(diags: *const diag.Diagnostics, sev: diag.Severity) usize {
    var n: usize = 0;
    for (diags.items.items) |it| {
        if (it.severity == sev) n += 1;
    }
    return n;
}

test "empty compat returns true and emits nothing" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .pi_version = null,
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkCompat(
        plugin.Compat{},
        host,
        "mypkg",
        "plugin.json",
        &d,
    );
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), d.items.items.len);
}

test "pluginApi ^1.0.0 against host 1.0.0 passes" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkCompat(
        plugin.Compat{ .pluginApi = "^1.0.0" },
        host,
        "mypkg",
        "plugin.json",
        &d,
    );
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), d.items.items.len);
}

test "pluginApi ^1.0.0 against host 2.0.0 fails with error" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "2.0.0",
    };
    const ok = try core_compat.checkCompat(
        plugin.Compat{ .pluginApi = "^1.0.0" },
        host,
        "mypkg",
        "plugin.json",
        &d,
    );
    try std.testing.expect(!ok);
    try std.testing.expect(findMessage(&d, "requires plugin API") != null);
    try std.testing.expect(findMessage(&d, "mypkg") != null);
    try std.testing.expectEqual(@as(usize, 1), countBySeverity(&d, .err));
}

test "minMcVersion >=0.2.0 against host 0.1.0 fails with precise message" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkCompat(
        plugin.Compat{ .minMcVersion = ">=0.2.0" },
        host,
        "tool",
        "plugin.json",
        &d,
    );
    try std.testing.expect(!ok);
    const msg = findMessage(&d, "requires mc");
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?.message, ">=0.2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?.message, "0.1.0") != null);
}

test "minPiVersion with null host emits warn and returns true" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .pi_version = null,
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkCompat(
        plugin.Compat{ .minPiVersion = "^0.3.0" },
        host,
        "needy",
        "plugin.json",
        &d,
    );
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), countBySeverity(&d, .err));
    try std.testing.expectEqual(@as(usize, 1), countBySeverity(&d, .warn));
    try std.testing.expect(findMessage(&d, "pi is not available") != null);
}

test "minPiVersion ^0.3.0 against host 0.3.5 passes" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .pi_version = "0.3.5",
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkCompat(
        plugin.Compat{ .minPiVersion = "^0.3.0" },
        host,
        "needy",
        "plugin.json",
        &d,
    );
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 0), d.items.items.len);
}

test "bad range in pluginApi yields error and returns false" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "1.0.0",
    };
    const ok = try core_compat.checkCompat(
        plugin.Compat{ .pluginApi = "not-a-range" },
        host,
        "bad",
        "plugin.json",
        &d,
    );
    try std.testing.expect(!ok);
    try std.testing.expect(findMessage(&d, "invalid semver range") != null);
}

test "detectHostFacts returns mc_version = MC_VERSION" {
    const facts = try core_compat.detectHostFacts(std.testing.allocator);
    try std.testing.expectEqualStrings(core_compat.MC_VERSION, facts.mc_version);
    try std.testing.expectEqualStrings(core_compat.PLUGIN_API, facts.plugin_api);
    // pi_version is environment-dependent — don't assert it.
    if (facts.pi_version) |pv| {
        std.testing.allocator.free(pv);
    }
}

test "downgradeErrorsToWarnings flips severity" {
    var d = diag.Diagnostics.init(std.testing.allocator);
    defer d.deinit();

    const host = core_compat.HostFacts{
        .mc_version = "0.1.0",
        .plugin_api = "1.0.0",
    };
    _ = try core_compat.checkCompat(
        plugin.Compat{ .minMcVersion = ">=99.0.0" },
        host,
        "x",
        "plugin.json",
        &d,
    );
    try std.testing.expectEqual(@as(usize, 1), countBySeverity(&d, .err));
    core_compat.downgradeErrorsToWarnings(&d);
    try std.testing.expectEqual(@as(usize, 0), countBySeverity(&d, .err));
    try std.testing.expectEqual(@as(usize, 1), countBySeverity(&d, .warn));
}
