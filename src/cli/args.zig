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
    help: void,
    version: void,
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
