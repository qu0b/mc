const std = @import("std");
const compat = @import("iocompat");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const init_cmd = @import("init.zig");
const add_cmd = @import("add.zig");
const remove_cmd = @import("remove.zig");
const install_cmd = @import("install.zig");
const list_cmd = @import("list.zig");
const search_cmd = @import("search.zig");
const info_cmd = @import("info.zig");
const marketplace_cmd = @import("marketplace.zig");
const generate_cmd = @import("generate.zig");
const agent_cmd = @import("agent.zig");
const validate_cmd = @import("validate.zig");
const run_cmd = @import("run.zig");

const VERSION = "0.1.0";

pub fn runWithArgs(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var iter = args_mod.SliceIterator{ .args = argv, .pos = 0 };
    const cmd = try args_mod.parse(&iter);

    switch (cmd) {
        .init => |opts| try init_cmd.execute(allocator, opts),
        .add => |opts| try add_cmd.execute(allocator, opts),
        .remove => |opts| try remove_cmd.execute(allocator, opts),
        .install => |opts| try install_cmd.execute(allocator, opts),
        .update => try install_cmd.execute(allocator, .{}),
        .list => |opts| try list_cmd.execute(allocator, opts),
        .search => |opts| try search_cmd.execute(allocator, opts),
        .info => |opts| try info_cmd.execute(allocator, opts),
        .marketplace => |sub| try marketplace_cmd.execute(allocator, sub),
        .generate => |sub| try generate_cmd.execute(allocator, sub),
        .agent => |sub| try agent_cmd.execute(allocator, sub),
        .validate => |opts| try validate_cmd.execute(allocator, opts),
        .run => |opts| try run_cmd.execute(allocator, .{
            .agent_name = opts.agent_name,
            .dry_run = opts.dry_run,
            .extra_args = opts.extra_args,
        }),
        .version => printVersion(),
        .help => printHelp(),
    }
}

fn printVersion() void {
    var w = compat.getStdout();
    w.print("mc {s}\n", .{VERSION});
    w.flush();
}

fn printHelp() void {
    var w = compat.getStdout();
    const help =
        \\mc - Zero-Copy Package Manager for Coding Assistants
        \\
        \\USAGE:
        \\  mc <command> [options]
        \\
        \\PACKAGE MANAGEMENT:
        \\  init [--name <name>]                    Create a new .mc/ sandbox
        \\  add <pkg> [-m <marketplace>] [-v <ver>]  Add a plugin
        \\  add --url <git-url>                      Add from git URL directly
        \\  add --path <local-path>                  Add from local path
        \\  remove <pkg>                             Remove a plugin
        \\  install                                  Install from mc.lock
        \\  update [<pkg>]                           Update packages
        \\
        \\INFORMATION:
        \\  list [--json]                            List installed plugins
        \\  search <query> [-m <marketplace>]        Search marketplaces
        \\  info <pkg>                               Show plugin details
        \\  validate                                 Check all config files + cross-refs; exit 1 on errors
        \\
        \\MARKETPLACE MANAGEMENT:
        \\  marketplace add <name> --github <repo>   Register a marketplace
        \\  marketplace add <name> --url <url>       Register from git URL
        \\  marketplace list                         List known marketplaces
        \\  marketplace remove <name>                Remove a marketplace
        \\  marketplace update [<name>]              Pull latest index
        \\
        \\CONFIG GENERATION:
        \\  generate mcp                             Generate merged .mcp.json
        \\  generate lsp                             Generate merged .lsp.json
        \\  generate hooks                           Generate merged hooks config
        \\  generate bees [--role <name>]             Generate per-role MCP configs for bees
        \\  generate all                             Regenerate everything
        \\
        \\AGENT MANAGEMENT:
        \\  agent new <name> [--model M] [--provider P] [--toolset T]   Create a new agent
        \\  agent show <name>                          Show an agent's materialized file trace
        \\  agent emit <name> [--target T]             Emit native config for a managed-agent
        \\                                             runtime (claude | openclaw | hermes | pi)
        \\
        \\AGENT EXECUTION:
        \\  run <agent> [--dry-run] [-- <pi args>]     Run a named agent
        \\
        \\ALIASES:
        \\  rm = remove, ls = list, s = search, mp = marketplace, gen = generate
        \\  i = install, -V = --version
        \\
        \\OPTIONS:
        \\  --help, -h                               Show this help
        \\  --version, -V                            Show version
        \\  --ignore-compat, -I                      (add/install) skip compat checks,
        \\                                           warn on violations instead of refusing
        \\
    ;
    w.writeAll(help);
    w.flush();
}
