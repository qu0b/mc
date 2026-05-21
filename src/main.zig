const std = @import("std");
const commands = @import("cli/commands.zig");
const compat = @import("iocompat");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    // Initialize the Zig 0.16 Io compat layer
    compat.initIo(allocator);

    // Read args from /proc/self/cmdline on Linux using low-level IO
    const cmdline = readCmdline(allocator) catch {
        commands.runWithArgs(allocator, &.{}) catch |err| {
            var w = compat.getStderr();
            w.print("error: {s}\n", .{@errorName(err)});
            w.flush();
            std.process.exit(1);
        };
        return;
    };

    // Split by null bytes
    var arg_list: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    for (cmdline, 0..) |byte, i| {
        if (byte == 0) {
            if (i > start) {
                try arg_list.append(allocator, cmdline[start..i]);
            }
            start = i + 1;
        }
    }

    commands.runWithArgs(allocator, arg_list.items) catch |err| {
        var w = compat.getStderr();
        w.print("error: {s}\n", .{@errorName(err)});
        w.flush();
        std.process.exit(1);
    };
}

fn readCmdline(allocator: std.mem.Allocator) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, "/proc/self/cmdline", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(fd);

    // Read in chunks since /proc files report size 0
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &tmp);
        if (n == 0) break;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    return buf.items;
}
