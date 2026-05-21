const std = @import("std");
const compat = @import("iocompat");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const sandbox = @import("../core/sandbox.zig");

pub fn execute(allocator: std.mem.Allocator, opts: args_mod.RemoveOpts) !void {
    var w = compat.getStdout();
    const cwd = try compat.realpathAlloc(allocator, ".");

    if (!sandbox.isSandbox(allocator, cwd)) {
        render.err(&w, "Not an mc project");
        w.writeAll(". Run 'mc init' first.\n");
        w.flush();
        return;
    }

    const plugins_dir = try sandbox.getPluginsDir(allocator, cwd);
    const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugins_dir, opts.package });

    compat.deleteTreeAbsolute(target);

    // Check if it was actually there by seeing if the directory still exists
    compat.accessAbsolute(target) catch {
        // Good - it's gone (or was never there, but we don't differentiate)
        render.success(&w, "Removed");
        w.print(" {s}\n", .{opts.package});
        w.flush();
        return;
    };

    // Still exists means deleteTree didn't fully work
    render.err(&w, "Failed to remove");
    w.print(": '{s}'\n", .{opts.package});
    w.flush();
}
