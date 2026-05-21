const std = @import("std");
const compat = @import("iocompat");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const sandbox = @import("../core/sandbox.zig");
const lockfile_mod = @import("../core/lockfile.zig");

pub fn execute(allocator: std.mem.Allocator, opts: args_mod.ListOpts) !void {
    var w = compat.getStdout();
    const cwd = try compat.realpathAlloc(allocator, ".");

    if (!sandbox.isSandbox(allocator, cwd)) {
        render.err(&w, "Not an mc project");
        w.writeAll(". Run 'mc init' first.\n");
        w.flush();
        return;
    }

    // Read from lock file for accurate info
    const lock = lockfile_mod.readLockFile(allocator, cwd) catch lockfile_mod.LockFile{};
    const packages = lockfile_mod.getLockedPackages(allocator, lock) catch &.{};

    // Also list from filesystem
    const installed = try sandbox.listInstalledPlugins(allocator, cwd);

    if (installed.len == 0 and packages.len == 0) {
        w.writeAll("No plugins installed.\n");
        w.flush();
        return;
    }

    if (opts.json) {
        printJson(&w, packages);
        w.flush();
        return;
    }

    render.header(&w, "Installed plugins:");
    const widths = [_]usize{ 30, 25, 10, 10 };
    render.tableRow(&w, &.{ "NAME", "MARKETPLACE", "VERSION", "SOURCE" }, &widths);
    render.tableRow(&w, &.{ "----", "-----------", "-------", "------" }, &widths);

    if (packages.len > 0) {
        for (packages) |pkg| {
            render.tableRow(&w, &.{
                pkg.name,
                pkg.marketplace,
                pkg.version,
                pkg.source_type,
            }, &widths);
        }
    } else {
        // Fall back to filesystem listing
        for (installed) |name| {
            render.tableRow(&w, &.{ name, "-", "-", "local" }, &widths);
        }
    }

    w.print("\n{d} plugin(s)\n", .{@max(packages.len, installed.len)});
    w.flush();
}

fn printJson(w: *compat.OutWriter, packages: []const lockfile_mod.LockedPackage) void {
    w.writeAll("[");
    for (packages, 0..) |pkg, i| {
        if (i > 0) w.writeAll(",");
        w.print("\n  {{\"name\":\"{s}\",\"marketplace\":\"{s}\",\"version\":\"{s}\",\"source\":\"{s}\"}}", .{
            pkg.name,
            pkg.marketplace,
            pkg.version,
            pkg.source_type,
        });
    }
    w.writeAll("\n]\n");
}
