const std = @import("std");
const compat = @import("iocompat");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const config = @import("../core/config.zig");
const git_mod = @import("../fetch/git.zig");
const github_mod = @import("../fetch/github.zig");
const marketplace_schema = @import("../schema/marketplace.zig");

pub fn execute(allocator: std.mem.Allocator, cmd: args_mod.MarketplaceCmd) !void {
    switch (cmd) {
        .add => |opts| try add(allocator, opts),
        .list => try list(allocator),
        .remove => |opts| try remove(allocator, opts),
        .update => |opts| try update(allocator, opts),
    }
}

fn add(allocator: std.mem.Allocator, opts: args_mod.MarketplaceAddOpts) !void {
    var w = compat.getStdout();

    try config.ensureHomeDirs(allocator);
    const mp_dir = try config.getMarketplacesDir(allocator);
    const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mp_dir, opts.name });

    // Check if already exists
    compat.accessAbsolute(target) catch {
        // Doesn't exist -- proceed
        if (opts.github) |repo| {
            const url = try github_mod.expandRepo(allocator, repo);
            w.print("Cloning {s}...\n", .{repo});
            try git_mod.clone(allocator, url, target, null);
        } else if (opts.url) |url| {
            w.print("Cloning {s}...\n", .{url});
            try git_mod.clone(allocator, url, target, null);
        } else {
            render.err(&w, "Must specify --github or --url\n");
            w.flush();
            return;
        }

        // Verify marketplace.json exists
        const mp_json = try std.fmt.allocPrint(allocator, "{s}/.claude-plugin/marketplace.json", .{target});
        compat.accessAbsolute(mp_json) catch {
            render.err(&w, "No .claude-plugin/marketplace.json found in repository\n");
            compat.deleteTreeAbsolute(target);
            w.flush();
            return;
        };

        // Parse to get info
        var parsed = marketplace_schema.parseMarketplace(allocator, mp_json) catch {
            render.success(&w, "Added");
            w.print(" marketplace '{s}'\n", .{opts.name});
            w.flush();
            return;
        };

        render.success(&w, "Added");
        w.print(" marketplace '{s}' ({d} plugins)\n", .{ parsed.value.name, parsed.value.plugins.len });
        parsed.deinit();
        w.flush();
        return;
    };

    render.warn(&w, "Marketplace already exists");
    w.print(": '{s}'. Use 'mc marketplace update {s}' to refresh.\n", .{ opts.name, opts.name });
    w.flush();
}

fn list(allocator: std.mem.Allocator) !void {
    var w = compat.getStdout();

    const refs = try config.listMarketplaces(allocator);

    if (refs.len == 0) {
        w.writeAll("No marketplaces configured.\n");
        w.writeAll("Add one: mc marketplace add <name> --github <owner/repo>\n");
        w.flush();
        return;
    }

    render.header(&w, "Known marketplaces:");

    for (refs) |ref| {
        render.bold(&w, ref.name);
        w.writeAll("\n");
        if (ref.install_path) |path| {
            render.kv(&w, "  Path", path);
        }

        // Try to parse and show plugin count
        if (ref.install_path) |path| {
            const mp_json = std.fmt.allocPrint(allocator, "{s}/.claude-plugin/marketplace.json", .{path}) catch continue;
            var parsed = marketplace_schema.parseMarketplace(allocator, mp_json) catch continue;
            w.print("  Plugins: {d}\n", .{parsed.value.plugins.len});
            parsed.deinit();
        }
        w.writeAll("\n");
    }
    w.flush();
}

fn remove(allocator: std.mem.Allocator, opts: args_mod.MarketplaceRemoveOpts) !void {
    var w = compat.getStdout();

    const mp_dir = try config.getMarketplacesDir(allocator);
    const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mp_dir, opts.name });

    compat.deleteTreeAbsolute(target);

    render.success(&w, "Removed");
    w.print(" marketplace '{s}'\n", .{opts.name});
    w.flush();
}

fn update(allocator: std.mem.Allocator, opts: args_mod.MarketplaceUpdateOpts) !void {
    var w = compat.getStdout();

    if (opts.name) |name| {
        const mp_dir = try config.getMarketplacesDir(allocator);
        const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mp_dir, name });

        w.print("Updating {s}...\n", .{name});
        git_mod.pull(allocator, target) catch {
            render.err(&w, "Failed to update");
            w.print(" '{s}'\n", .{name});
            w.flush();
            return;
        };
        render.success(&w, "Updated");
        w.print(" '{s}'\n", .{name});
    } else {
        // Update all
        const refs = try config.listMarketplaces(allocator);
        for (refs) |ref| {
            if (ref.install_path) |path| {
                w.print("Updating {s}...\n", .{ref.name});
                git_mod.pull(allocator, path) catch {
                    render.warn(&w, "Failed to update");
                    w.print(" '{s}'\n", .{ref.name});
                    continue;
                };
            }
        }
        render.success(&w, "All marketplaces updated\n");
    }
    w.flush();
}
