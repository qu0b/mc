const std = @import("std");

/// Simple iterator over a slice of string args.
pub const SliceIterator = struct {
    args: []const []const u8,
    pos: usize,

    pub fn next(self: *SliceIterator) ?[]const u8 {
        if (self.pos >= self.args.len) return null;
        const arg = self.args[self.pos];
        self.pos += 1;
        return arg;
    }
};

pub const Command = union(enum) {
    init: InitOpts,
    add: AddOpts,
    remove: RemoveOpts,
    install: InstallOpts,
    update: UpdateOpts,
    list: ListOpts,
    search: SearchOpts,
    info: InfoOpts,
    marketplace: MarketplaceCmd,
    generate: GenerateCmd,
    agent: AgentSub,
    validate: ValidateOpts,
    run: RunOpts,
    help: void,
    version: void,
};

pub const ValidateOpts = struct {
    // Reserved for future flags.
};

pub const RunOpts = struct {
    agent_name: []const u8,
    dry_run: bool = false,
    /// Args collected after `--`, passed through to `pi`.
    extra_args: []const []const u8 = &.{},
};

pub const InitOpts = struct {
    name: ?[]const u8 = null,
};

pub const AddOpts = struct {
    package: ?[]const u8 = null,
    marketplace: ?[]const u8 = null,
    version: ?[]const u8 = null,
    url: ?[]const u8 = null,
    path: ?[]const u8 = null,
    ignore_compat: bool = false,
};

pub const InstallOpts = struct {
    ignore_compat: bool = false,
};

pub const RemoveOpts = struct {
    package: []const u8,
};

pub const UpdateOpts = struct {
    package: ?[]const u8 = null,
};

pub const ListOpts = struct {
    json: bool = false,
};

pub const SearchOpts = struct {
    query: []const u8,
    marketplace: ?[]const u8 = null,
};

pub const InfoOpts = struct {
    package: []const u8,
};

pub const MarketplaceCmd = union(enum) {
    add: MarketplaceAddOpts,
    list: void,
    remove: MarketplaceRemoveOpts,
    update: MarketplaceUpdateOpts,
};

pub const MarketplaceAddOpts = struct {
    name: []const u8,
    github: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const MarketplaceRemoveOpts = struct {
    name: []const u8,
};

pub const MarketplaceUpdateOpts = struct {
    name: ?[]const u8 = null,
};

pub const GenerateCmd = union(enum) {
    mcp: void,
    lsp: void,
    hooks: void,
    bees: GenerateBeesOpts,
    all: void,
};

pub const GenerateBeesOpts = struct {
    /// Only generate for a specific role.
    role: ?[]const u8 = null,
};

pub const AgentSub = union(enum) {
    new: AgentNewOpts,
    show: AgentShowOpts,
    // TODO(phase-later): validate
};

pub const AgentNewOpts = struct {
    name: []const u8,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    toolset: ?[]const u8 = null,
};

pub const AgentShowOpts = struct {
    name: []const u8,
    // TODO(phase-later): --json, --files-only, etc.
};

pub fn parse(args_iter: anytype) !Command {
    // Skip program name
    _ = args_iter.next();

    const cmd = args_iter.next() orelse return .help;

    if (std.mem.eql(u8, cmd, "init")) {
        var opts = InitOpts{};
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--name")) {
                opts.name = args_iter.next();
            }
        }
        return .{ .init = opts };
    } else if (std.mem.eql(u8, cmd, "add")) {
        var opts = AddOpts{};
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--marketplace") or std.mem.eql(u8, arg, "-m")) {
                opts.marketplace = args_iter.next();
            } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
                opts.version = args_iter.next();
            } else if (std.mem.eql(u8, arg, "--url")) {
                opts.url = args_iter.next();
            } else if (std.mem.eql(u8, arg, "--path")) {
                opts.path = args_iter.next();
            } else if (std.mem.eql(u8, arg, "--ignore-compat") or std.mem.eql(u8, arg, "-I")) {
                opts.ignore_compat = true;
            } else if (!std.mem.startsWith(u8, arg, "-")) {
                opts.package = arg;
            }
        }
        return .{ .add = opts };
    } else if (std.mem.eql(u8, cmd, "remove") or std.mem.eql(u8, cmd, "rm")) {
        const pkg = args_iter.next() orelse return error.MissingArgument;
        return .{ .remove = .{ .package = pkg } };
    } else if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "i")) {
        var opts = InstallOpts{};
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--ignore-compat") or std.mem.eql(u8, arg, "-I")) {
                opts.ignore_compat = true;
            }
        }
        return .{ .install = opts };
    } else if (std.mem.eql(u8, cmd, "update")) {
        return .{ .update = .{ .package = args_iter.next() } };
    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
        var opts = ListOpts{};
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) opts.json = true;
        }
        return .{ .list = opts };
    } else if (std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "s")) {
        const query = args_iter.next() orelse return error.MissingArgument;
        var marketplace: ?[]const u8 = null;
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--marketplace") or std.mem.eql(u8, arg, "-m")) {
                marketplace = args_iter.next();
            }
        }
        return .{ .search = .{ .query = query, .marketplace = marketplace } };
    } else if (std.mem.eql(u8, cmd, "info")) {
        const pkg = args_iter.next() orelse return error.MissingArgument;
        return .{ .info = .{ .package = pkg } };
    } else if (std.mem.eql(u8, cmd, "marketplace") or std.mem.eql(u8, cmd, "mp")) {
        return parseMarketplace(args_iter);
    } else if (std.mem.eql(u8, cmd, "generate") or std.mem.eql(u8, cmd, "gen")) {
        return parseGenerate(args_iter);
    } else if (std.mem.eql(u8, cmd, "agent")) {
        return parseAgent(args_iter);
    } else if (std.mem.eql(u8, cmd, "validate")) {
        return .{ .validate = .{} };
    } else if (std.mem.eql(u8, cmd, "run")) {
        return parseRun(args_iter);
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        return .version;
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        return .help;
    }

    return .help;
}

fn parseMarketplace(args_iter: anytype) !Command {
    const sub = args_iter.next() orelse return .{ .marketplace = .{ .list = {} } };

    if (std.mem.eql(u8, sub, "add")) {
        const name = args_iter.next() orelse return error.MissingArgument;
        var opts = MarketplaceAddOpts{ .name = name };
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--github") or std.mem.eql(u8, arg, "-g")) {
                opts.github = args_iter.next();
            } else if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
                opts.url = args_iter.next();
            }
        }
        return .{ .marketplace = .{ .add = opts } };
    } else if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "ls")) {
        return .{ .marketplace = .{ .list = {} } };
    } else if (std.mem.eql(u8, sub, "remove") or std.mem.eql(u8, sub, "rm")) {
        const name = args_iter.next() orelse return error.MissingArgument;
        return .{ .marketplace = .{ .remove = .{ .name = name } } };
    } else if (std.mem.eql(u8, sub, "update")) {
        return .{ .marketplace = .{ .update = .{ .name = args_iter.next() } } };
    }

    return .help;
}

fn parseAgent(args_iter: anytype) !Command {
    const sub = args_iter.next() orelse return error.MissingArgument;

    if (std.mem.eql(u8, sub, "new")) {
        const name = args_iter.next() orelse return error.MissingArgument;
        var opts = AgentNewOpts{ .name = name };
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--model")) {
                opts.model = args_iter.next();
            } else if (std.mem.eql(u8, arg, "--provider")) {
                opts.provider = args_iter.next();
            } else if (std.mem.eql(u8, arg, "--toolset")) {
                opts.toolset = args_iter.next();
            }
        }
        return .{ .agent = .{ .new = opts } };
    } else if (std.mem.eql(u8, sub, "show")) {
        const name = args_iter.next() orelse return error.MissingArgument;
        return .{ .agent = .{ .show = .{ .name = name } } };
    }

    return error.UnknownSubcommand;
}

fn parseRun(args_iter: anytype) !Command {
    // Collect all remaining args; parsing order matters for the `--` split.
    var remaining: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(std.heap.page_allocator);
    // remaining lives for the lifetime of the program (main).  Reuse page_allocator
    // since Command owns borrowed slices from the original argv anyway.
    while (args_iter.next()) |a| try remaining.append(a);
    const items = remaining.items;

    var name: ?[]const u8 = null;
    var dry_run = false;
    var extra: []const []const u8 = &.{};

    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const arg = items[i];
        if (std.mem.eql(u8, arg, "--")) {
            extra = items[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and name == null) {
            name = arg;
        }
    }

    const agent_name = name orelse return error.MissingArgument;
    return .{ .run = .{
        .agent_name = agent_name,
        .dry_run = dry_run,
        .extra_args = extra,
    } };
}

fn parseGenerate(args_iter: anytype) !Command {
    const sub = args_iter.next() orelse return .{ .generate = .{ .all = {} } };

    if (std.mem.eql(u8, sub, "mcp")) return .{ .generate = .{ .mcp = {} } };
    if (std.mem.eql(u8, sub, "lsp")) return .{ .generate = .{ .lsp = {} } };
    if (std.mem.eql(u8, sub, "hooks")) return .{ .generate = .{ .hooks = {} } };
    if (std.mem.eql(u8, sub, "bees")) {
        var opts = GenerateBeesOpts{};
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--role") or std.mem.eql(u8, arg, "-r")) {
                opts.role = args_iter.next();
            }
        }
        return .{ .generate = .{ .bees = opts } };
    }
    if (std.mem.eql(u8, sub, "all")) return .{ .generate = .{ .all = {} } };

    return .{ .generate = .{ .all = {} } };
}
