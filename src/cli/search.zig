const std = @import("std");
const compat = @import("../io/compat.zig");
const args_mod = @import("args.zig");
const render = @import("render.zig");
const resolver = @import("../core/resolver.zig");

pub fn execute(allocator: std.mem.Allocator, opts: args_mod.SearchOpts) !void {
    var w = compat.getStdout();

    const results = try resolver.search(allocator, opts.query);

    if (results.len == 0) {
        render.warn(&w, "No plugins found");
        w.print(" for '{s}'\n", .{opts.query});
        w.writeAll("Run 'mc marketplace list' to check available marketplaces.\n");
        w.flush();
        return;
    }

    w.print("Found {d} plugin(s) matching '{s}':\n\n", .{ results.len, opts.query });

    for (results) |r| {
        render.bold(&w, r.name);
        render.color(&w, .dim);
        w.print(" @{s}", .{r.marketplace});
        render.color(&w, .reset);
        if (r.version) |v| w.print(" v{s}", .{v});
        w.writeAll("\n");

        if (r.description) |desc| {
            render.color(&w, .dim);
            w.print("  {s}\n", .{desc});
            render.color(&w, .reset);
        }

        if (r.category) |cat| {
            w.print("  [{s}]\n", .{cat});
        }
        w.writeAll("\n");
    }
    w.flush();
}
