const std = @import("std");
const compat = @import("../io/compat.zig");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const sandbox = @import("../core/sandbox.zig");

pub fn execute(allocator: std.mem.Allocator, opts: args_mod.InitOpts) !void {
    var w = compat.getStdout();

    const cwd = try compat.realpathAlloc(allocator, ".");

    if (sandbox.isSandbox(allocator, cwd)) {
        render.warn(&w, "Already initialized");
        w.writeAll(" (.mc/ exists in current directory)\n");
        w.flush();
        return;
    }

    try sandbox.init(allocator, cwd, opts.name);

    render.success(&w, "Initialized");
    if (opts.name) |name| {
        w.print(" project '{s}'\n", .{name});
    } else {
        w.print(" project in {s}\n", .{std.fs.path.basename(cwd)});
    }

    render.info(&w, "Created:");
    w.writeAll("\n");
    w.writeAll("  .mc/mc.json     Project manifest\n");
    w.writeAll("  .mc/plugins/    Plugin install directory\n");
    w.writeAll("\nNext: mc marketplace add <name> --github <owner/repo>\n");
    w.flush();
}
