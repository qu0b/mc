const std = @import("std");
const compat = @import("iocompat");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const sandbox = @import("../core/sandbox.zig");
const mcp_mod = @import("../schema/mcp.zig");
const lsp_mod = @import("../schema/lsp.zig");
const hooks_mod = @import("../schema/hooks.zig");
const plugin_mod = @import("plugin");
const json_mod = @import("json");
const writer_mod = @import("../io/writer.zig");

pub fn execute(allocator: std.mem.Allocator, cmd: args_mod.GenerateCmd) !void {
    var w = compat.getStdout();
    const cwd = try compat.realpathAlloc(allocator, ".");

    if (!sandbox.isSandbox(allocator, cwd)) {
        render.err(&w, "Not an mc project");
        w.writeAll(". Run 'mc init' first.\n");
        w.flush();
        return;
    }

    switch (cmd) {
        .mcp => try generateMcp(allocator, &w, cwd),
        .lsp => try generateLsp(allocator, &w, cwd),
        .hooks => try generateHooks(allocator, &w, cwd),
        .bees => |opts| try generateBees(allocator, &w, cwd, opts.role),
        .all => {
            try generateMcp(allocator, &w, cwd);
            try generateLsp(allocator, &w, cwd);
            try generateHooks(allocator, &w, cwd);
        },
    }
    w.flush();
}

fn generateMcp(allocator: std.mem.Allocator, w: *compat.OutWriter, cwd: []const u8) !void {
    const plugins_dir = try sandbox.getPluginsDir(allocator, cwd);
    const installed = try sandbox.listInstalledPlugins(allocator, cwd);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"mcpServers\": {");

    var count: usize = 0;
    for (installed) |name| {
        const mcp_path = try std.fmt.allocPrint(allocator, "{s}/{s}/.mcp.json", .{ plugins_dir, name });
        const plugin_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugins_dir, name });

        const file_content = compat.readFile(allocator, mcp_path) catch continue;
        const config_val = json_mod.parseSlice(mcp_mod.McpConfig, allocator, file_content) catch continue;
        const servers = mcp_mod.extractServers(allocator, config_val) catch continue;

        for (servers) |server| {
            if (count > 0) try buf.appendSlice(allocator, ",");
            try buf.print(allocator, "\n    \"{s}\": {{", .{server.name});

            if (server.command) |cmd| {
                const expanded = try mcp_mod.expandTemplateVars(allocator, cmd, plugin_root, null);
                try buf.print(allocator, "\n      \"command\": \"{s}\"", .{expanded});
            }

            if (server.args) |args| {
                try buf.appendSlice(allocator, ",\n      \"args\": [");
                for (args, 0..) |arg, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    const expanded = try mcp_mod.expandTemplateVars(allocator, arg, plugin_root, null);
                    try buf.print(allocator, "\"{s}\"", .{expanded});
                }
                try buf.appendSlice(allocator, "]");
            }

            try buf.appendSlice(allocator, "\n    }");
            count += 1;
        }
    }

    try buf.appendSlice(allocator, "\n  }\n}\n");

    if (count > 0) {
        try writer_mod.atomicWriteFile(cwd, ".mcp.json", buf.items);
        render.success(w, "Generated");
        w.print(" .mcp.json ({d} servers)\n", .{count});
    } else {
        w.writeAll("No MCP servers found in installed plugins.\n");
    }
}

fn generateLsp(allocator: std.mem.Allocator, w: *compat.OutWriter, cwd: []const u8) !void {
    const plugins_dir = try sandbox.getPluginsDir(allocator, cwd);
    const installed = try sandbox.listInstalledPlugins(allocator, cwd);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{");

    var count: usize = 0;
    for (installed) |name| {
        const lsp_path = try std.fmt.allocPrint(allocator, "{s}/{s}/.lsp.json", .{ plugins_dir, name });

        const file_content = compat.readFile(allocator, lsp_path) catch continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, file_content, .{
            .allocate = .alloc_if_needed,
        }) catch continue;

        const servers = lsp_mod.extractLspServers(allocator, value) catch continue;

        for (servers) |server| {
            if (count > 0) try buf.appendSlice(allocator, ",");
            try buf.print(allocator, "\n  \"{s}\": {{\n    \"command\": \"{s}\"", .{ server.name, server.command });

            if (server.args) |args| {
                try buf.appendSlice(allocator, ",\n    \"args\": [");
                for (args, 0..) |arg, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.print(allocator, "\"{s}\"", .{arg});
                }
                try buf.appendSlice(allocator, "]");
            }

            if (server.extension_to_language) |mappings| {
                try buf.appendSlice(allocator, ",\n    \"extensionToLanguage\": {");
                for (mappings, 0..) |m, i| {
                    if (i > 0) try buf.appendSlice(allocator, ",");
                    try buf.print(allocator, "\n      \"{s}\": \"{s}\"", .{ m.extension, m.language });
                }
                try buf.appendSlice(allocator, "\n    }");
            }

            try buf.appendSlice(allocator, "\n  }");
            count += 1;
        }
    }

    try buf.appendSlice(allocator, "\n}\n");

    if (count > 0) {
        try writer_mod.atomicWriteFile(cwd, ".lsp.json", buf.items);
        render.success(w, "Generated");
        w.print(" .lsp.json ({d} servers)\n", .{count});
    } else {
        w.writeAll("No LSP servers found in installed plugins.\n");
    }
}

fn generateHooks(allocator: std.mem.Allocator, w: *compat.OutWriter, cwd: []const u8) !void {
    const plugins_dir = try sandbox.getPluginsDir(allocator, cwd);
    const installed = try sandbox.listInstalledPlugins(allocator, cwd);

    var count: usize = 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n  \"hooks\": {");

    for (installed) |name| {
        const hooks_path = try std.fmt.allocPrint(allocator, "{s}/{s}/hooks/hooks.json", .{ plugins_dir, name });

        const file_content = compat.readFile(allocator, hooks_path) catch continue;

        // Just include the raw hooks content (it's already in the right format)
        if (count > 0) try buf.appendSlice(allocator, ",");
        // We'd need to merge hooks properly here -- for MVP just note it was found
        _ = file_content;
        count += 1;
    }

    try buf.appendSlice(allocator, "\n  }\n}\n");

    if (count > 0) {
        render.success(w, "Found");
        w.print(" hooks from {d} plugin(s)\n", .{count});
    } else {
        w.writeAll("No hooks found in installed plugins.\n");
    }
}

/// Generate per-role MCP config files for bees agent roles.
/// For each role in .bees/roles/ that references mc plugins,
/// writes a merged .mcp.json combining plugin MCP servers.
fn generateBees(allocator: std.mem.Allocator, w: *compat.OutWriter, cwd: []const u8, only_role: ?[]const u8) !void {
    if (!sandbox.isSandbox(allocator, cwd)) {
        render.err(w, "Not an mc project");
        w.writeAll(". Run 'mc init' first.\n");
        w.flush();
        return;
    }

    // Check for .bees/ directory
    const bees_roles_dir = try std.fmt.allocPrint(allocator, "{s}/.bees/roles", .{cwd});
    compat.accessAbsolute(bees_roles_dir) catch {
        render.err(w, "No .bees/roles/ directory found");
        w.writeAll(". Run 'bees init' first.\n");
        w.flush();
        return;
    };

    const plugins_dir = try sandbox.getPluginsDir(allocator, cwd);
    const installed = try sandbox.listInstalledPlugins(allocator, cwd);

    if (installed.len == 0) {
        w.writeAll("No mc plugins installed. Run 'mc add <plugin>' first.\n");
        w.flush();
        return;
    }

    // Scan .bees/roles/ for subdirectories
    const dir = try compat.openDirAbsolute(bees_roles_dir);
    var role_iter = compat.iterateDir(dir);

    var generated: usize = 0;
    while (try role_iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (only_role) |r| {
            if (!std.mem.eql(u8, entry.name, r)) continue;
        }

        const role_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bees_roles_dir, entry.name });
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{role_dir});

        // Read role config to check for "plugins" field
        const config_data = compat.readFile(allocator, config_path) catch continue;

        // Parse just enough to find plugins array — look for plugin names
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, config_data, .{
            .allocate = .alloc_if_needed,
        }) catch continue;

        const plugins_val = switch (parsed) {
            .object => |obj| obj.get("plugins") orelse continue,
            else => continue,
        };
        const plugins_arr = switch (plugins_val) {
            .array => |a| a,
            else => continue,
        };

        if (plugins_arr.items.len == 0) continue;

        // Build merged MCP config for this role
        var mcp_buf: std.ArrayList(u8) = .empty;
        defer mcp_buf.deinit(allocator);

        try mcp_buf.appendSlice(allocator, "{\n  \"mcpServers\": {");
        var server_count: usize = 0;

        for (plugins_arr.items) |plugin_item| {
            const plugin_name = switch (plugin_item) {
                .object => |obj| blk: {
                    const name_val = obj.get("name") orelse continue;
                    break :blk switch (name_val) {
                        .string => |s| s,
                        else => continue,
                    };
                },
                .string => |s| s,
                else => continue,
            };

            // Check if plugin is installed
            var found = false;
            for (installed) |inst| {
                if (std.mem.eql(u8, inst, plugin_name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                w.print("  Warning: plugin '{s}' not installed (referenced by role '{s}')\n", .{ plugin_name, entry.name });
                continue;
            }

            // Read plugin's .mcp.json
            const mcp_path = try std.fmt.allocPrint(allocator, "{s}/{s}/.mcp.json", .{ plugins_dir, plugin_name });
            const plugin_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugins_dir, plugin_name });

            const file_content = compat.readFile(allocator, mcp_path) catch continue;
            const config_val = json_mod.parseSlice(mcp_mod.McpConfig, allocator, file_content) catch continue;
            const servers = mcp_mod.extractServers(allocator, config_val) catch continue;

            for (servers) |server| {
                if (server_count > 0) try mcp_buf.appendSlice(allocator, ",");
                try mcp_buf.print(allocator, "\n    \"{s}\": {{", .{server.name});

                if (server.command) |cmd| {
                    const expanded = try mcp_mod.expandTemplateVars(allocator, cmd, plugin_root, null);
                    try mcp_buf.print(allocator, "\n      \"command\": \"{s}\"", .{expanded});
                }

                if (server.args) |args| {
                    try mcp_buf.appendSlice(allocator, ",\n      \"args\": [");
                    for (args, 0..) |arg, i| {
                        if (i > 0) try mcp_buf.appendSlice(allocator, ", ");
                        const expanded = try mcp_mod.expandTemplateVars(allocator, arg, plugin_root, null);
                        try mcp_buf.print(allocator, "\"{s}\"", .{expanded});
                    }
                    try mcp_buf.appendSlice(allocator, "]");
                }

                try mcp_buf.appendSlice(allocator, "\n    }");
                server_count += 1;
            }
        }

        try mcp_buf.appendSlice(allocator, "\n  }\n}\n");

        if (server_count > 0) {
            const out_path = try std.fmt.allocPrint(allocator, "{s}/mcp.json", .{role_dir});
            try writer_mod.atomicWriteFile(role_dir, "mcp.json", mcp_buf.items);
            _ = out_path;
            generated += 1;
            render.success(w, "Generated");
            w.print(" .bees/roles/{s}/mcp.json ({d} servers)\n", .{ entry.name, server_count });
        }
    }

    if (generated == 0) {
        w.writeAll("No roles with plugin references found.\n");
    }
    w.flush();
}
