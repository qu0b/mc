const std = @import("std");
const compat = @import("../io/compat.zig");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const sandbox = @import("../core/sandbox.zig");
const lockfile_mod = @import("../core/lockfile.zig");
const cache_store = @import("../cache/store.zig");
const core_compat = @import("../core/compat.zig");
const diag = @import("diagnostic");

pub fn execute(allocator: std.mem.Allocator, opts: args_mod.InstallOpts) !void {
    var w = compat.getStdout();
    const cwd = try compat.realpathAlloc(allocator, ".");

    if (!sandbox.isSandbox(allocator, cwd)) {
        render.err(&w, "Not an mc project");
        w.writeAll(". Run 'mc init' first.\n");
        w.flush();
        return;
    }

    const lock = lockfile_mod.readLockFile(allocator, cwd) catch {
        render.warn(&w, "No lock file found");
        w.writeAll(". Nothing to install.\n");
        w.flush();
        return;
    };

    const packages = try lockfile_mod.getLockedPackages(allocator, lock);
    if (packages.len == 0) {
        w.writeAll("No packages in lock file.\n");
        w.flush();
        return;
    }

    const plugins_dir = try sandbox.getPluginsDir(allocator, cwd);
    compat.makeDirAbsolute(plugins_dir) catch {};

    var store = try cache_store.ContentStore.init(allocator);

    // ---- Pre-flight compat check across the whole batch ----
    // Partial installs leave the sandbox in an ambiguous state, so we
    // validate every package BEFORE we link a single one.
    var diags = diag.Diagnostics.init(allocator);
    defer diags.deinit();
    const host = try core_compat.detectHostFacts(allocator);
    var any_fail = false;

    for (packages) |pkg| {
        if (pkg.content_hash.len == 0) continue;
        if (!store.has(allocator, pkg.content_hash)) continue;
        const cache_path = try store.getPath(allocator, pkg.content_hash);
        const ok = try core_compat.checkPluginDir(allocator, cache_path, pkg.name, host, &diags);
        if (!ok) any_fail = true;
    }

    if (diags.count() > 0) {
        if (any_fail and !opts.ignore_compat) {
            try renderDiagnostics(allocator, &w, &diags);
            render.err(&w, "Refusing install");
            w.writeAll(" — compat violations (pass --ignore-compat to override)\n");
            w.flush();
            std.process.exit(1);
        }
        if (opts.ignore_compat and any_fail) {
            core_compat.downgradeErrorsToWarnings(&diags);
        }
        try renderDiagnostics(allocator, &w, &diags);
        if (opts.ignore_compat and any_fail) {
            render.warn(&w, "ignored compat violations (--ignore-compat)\n");
        }
    }

    // ---- Link stage ----
    var installed: usize = 0;
    var skipped: usize = 0;

    for (packages) |pkg| {
        if (pkg.content_hash.len == 0) {
            skipped += 1;
            continue;
        }

        // Check if in cache
        if (store.has(allocator, pkg.content_hash)) {
            const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugins_dir, pkg.name });
            store.link(allocator, pkg.content_hash, target) catch {
                skipped += 1;
                continue;
            };
            installed += 1;
        } else {
            render.warn(&w, "Cache miss");
            w.print(" for {s} (hash: {s}). Run 'mc add {s}' to re-fetch.\n", .{ pkg.name, pkg.content_hash, pkg.name });
            skipped += 1;
        }
    }

    render.success(&w, "Installed");
    w.print(" {d} packages", .{installed});
    if (skipped > 0) {
        w.print(" ({d} skipped)", .{skipped});
    }
    w.writeAll("\n");
    w.flush();
}

fn renderDiagnostics(
    allocator: std.mem.Allocator,
    w: *compat.OutWriter,
    diags: *const diag.Diagnostics,
) !void {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try diags.render(buf.writer());
    w.writeAll(buf.items);
}
