const std = @import("std");
const compat = @import("iocompat");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const resolver = @import("../core/resolver.zig");
const source_mod = @import("../schema/source.zig");
const plugin_mod = @import("plugin");
const json_mod = @import("json");

pub fn execute(allocator: std.mem.Allocator, opts: args_mod.InfoOpts) !void {
    var w = compat.getStdout();

    const resolved = resolver.resolve(allocator, opts.package) catch {
        render.err(&w, "Plugin not found");
        w.print(": '{s}'\n", .{opts.package});
        w.flush();
        return;
    };

    render.header(&w, resolved.name);
    render.kv(&w, "  Marketplace", resolved.marketplace_name);

    if (resolved.entry.description) |desc| {
        render.kv(&w, "  Description", desc);
    }
    if (resolved.entry.version) |v| {
        render.kv(&w, "  Version    ", v);
    }
    if (resolved.entry.homepage) |hp| {
        render.kv(&w, "  Homepage   ", hp);
    }
    if (resolved.entry.category) |cat| {
        render.kv(&w, "  Category   ", cat);
    }
    if (resolved.entry.author) |author| {
        render.kv(&w, "  Author     ", author.name);
    }

    // Source info
    w.writeAll("\n  Source:\n");
    switch (resolved.source) {
        .local => |path| {
            render.kv(&w, "    Type", "local");
            render.kv(&w, "    Path", path);
        },
        .github => |gh| {
            render.kv(&w, "    Type", "github");
            render.kv(&w, "    Repo", gh.repo);
            if (gh.sha) |sha| render.kv(&w, "    SHA ", sha);
        },
        .url => |u| {
            render.kv(&w, "    Type", "git");
            render.kv(&w, "    URL ", u.url);
            if (u.sha) |sha| render.kv(&w, "    SHA ", sha);
        },
        .git_subdir => |gs| {
            render.kv(&w, "    Type", "git-subdir");
            render.kv(&w, "    URL ", gs.url);
            render.kv(&w, "    Path", gs.path);
        },
        .npm => |n| {
            render.kv(&w, "    Type   ", "npm");
            render.kv(&w, "    Package", n.package);
        },
    }

    // Components
    w.writeAll("\n  Components:\n");
    if (resolved.entry.skills != null) w.writeAll("    - Skills\n");
    if (resolved.entry.commands != null) w.writeAll("    - Commands\n");
    if (resolved.entry.agents != null) w.writeAll("    - Agents\n");
    if (resolved.entry.hooks != null) w.writeAll("    - Hooks\n");
    if (resolved.entry.mcpServers != null) w.writeAll("    - MCP Servers\n");
    if (resolved.entry.lspServers != null) w.writeAll("    - LSP Servers\n");

    if (resolved.entry.tags) |tags| {
        w.writeAll("\n  Tags: ");
        for (tags, 0..) |tag, i| {
            if (i > 0) w.writeAll(", ");
            w.writeAll(tag);
        }
        w.writeAll("\n");
    }

    w.writeAll("\n  Install: mc add ");
    w.writeAll(resolved.name);
    w.writeAll("\n");
    w.flush();
}
