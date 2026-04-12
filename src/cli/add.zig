const std = @import("std");
const compat = @import("../io/compat.zig");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const sandbox = @import("../core/sandbox.zig");
const resolver = @import("../core/resolver.zig");
const fetcher = @import("../fetch/fetcher.zig");
const lockfile_mod = @import("../core/lockfile.zig");
const source_mod = @import("../schema/source.zig");
const local_mod = @import("../fetch/local.zig");
const git_mod = @import("../fetch/git.zig");
const github_mod = @import("../fetch/github.zig");
const cache_store = @import("../cache/store.zig");
const hash_mod = @import("../io/hash.zig");

pub fn execute(allocator: std.mem.Allocator, opts: args_mod.AddOpts) !void {
    var w = compat.getStdout();
    const cwd = try compat.realpathAlloc(allocator, ".");

    if (!sandbox.isSandbox(allocator, cwd)) {
        render.err(&w, "Not an mc project");
        w.writeAll(". Run 'mc init' first.\n");
        w.flush();
        return;
    }

    const plugins_dir = try sandbox.getPluginsDir(allocator, cwd);
    compat.makeDirAbsolute(plugins_dir) catch {};

    // Direct URL or path add
    if (opts.url != null or opts.path != null) {
        try addDirect(allocator, &w, cwd, plugins_dir, opts);
        return;
    }

    // Package name add (resolve from marketplaces)
    const pkg = opts.package orelse {
        render.err(&w, "Missing package name");
        w.writeAll(". Usage: mc add <package>\n");
        w.flush();
        return;
    };

    w.print("Resolving {s}...\n", .{pkg});

    const resolved = resolver.resolve(allocator, pkg) catch {
        render.err(&w, "Plugin not found");
        w.print(": '{s}'\n", .{pkg});
        w.writeAll("Run 'mc marketplace list' to see available marketplaces.\n");
        w.flush();
        return;
    };

    w.print("Found {s} in {s}\n", .{ resolved.name, resolved.marketplace_name });
    w.writeAll("Fetching...\n");

    const result = try fetcher.fetch(
        allocator,
        resolved.source,
        resolved.name,
        resolved.marketplace_name,
        resolved.marketplace_path,
        plugins_dir,
    );

    // Update lock file
    const lock = lockfile_mod.readLockFile(allocator, cwd) catch lockfile_mod.LockFile{};
    const existing = lockfile_mod.getLockedPackages(allocator, lock) catch &.{};
    var pkgs: std.ArrayList(lockfile_mod.LockedPackage) = .empty;
    for (existing) |p| try pkgs.append(allocator, p);

    try pkgs.append(allocator, .{
        .name = resolved.name,
        .marketplace = resolved.marketplace_name,
        .version = resolved.entry.version orelse "latest",
        .content_hash = result.content_hash,
        .source_type = resolved.source.description(),
        .git_sha = result.git_sha,
    });

    try lockfile_mod.writeLockFile(allocator, cwd, pkgs.items);

    render.success(&w, "Installed");
    w.print(" {s}", .{resolved.name});
    if (resolved.entry.version) |v| w.print("@{s}", .{v});
    w.writeAll("\n");
    w.flush();
}

fn addDirect(
    allocator: std.mem.Allocator,
    w: *compat.OutWriter,
    cwd: []const u8,
    plugins_dir: []const u8,
    opts: args_mod.AddOpts,
) !void {
    var store = try cache_store.ContentStore.init(allocator);
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/mc-direct-add", .{});
    compat.deleteTreeAbsolute(tmp_dir);
    try compat.makeDirAbsolute(tmp_dir);
    defer compat.deleteTreeAbsolute(tmp_dir);

    var source_dir: []const u8 = undefined;
    var name: []const u8 = "direct-plugin";
    var source_type: []const u8 = "local";

    if (opts.path) |path| {
        source_dir = try local_mod.resolvePath(allocator, cwd, path);
        name = std.fs.path.basename(source_dir);
        source_type = "local";
    } else if (opts.url) |url| {
        w.print("Cloning {s}...\n", .{url});
        try git_mod.clone(allocator, url, tmp_dir, null);
        source_dir = tmp_dir;
        // Derive name from URL
        const base = std.fs.path.basename(url);
        name = if (std.mem.endsWith(u8, base, ".git")) base[0 .. base.len - 4] else base;
        source_type = "url";
    } else return;

    const content_hash = try store.store(allocator, source_dir);
    const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugins_dir, name });
    try store.link(allocator, content_hash, target);

    render.success(w, "Installed");
    w.print(" {s} (direct)\n", .{name});
    w.flush();

    // Update lock file
    var pkgs: std.ArrayList(lockfile_mod.LockedPackage) = .empty;
    try pkgs.append(allocator, .{
        .name = name,
        .marketplace = "direct",
        .version = "latest",
        .content_hash = content_hash,
        .source_type = source_type,
    });
    lockfile_mod.writeLockFile(allocator, cwd, pkgs.items) catch {};
}
