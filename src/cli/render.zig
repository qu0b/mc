const std = @import("std");
const compat = @import("../io/compat.zig");

const Writer = compat.OutWriter;

// ANSI color codes
pub const Color = enum {
    reset,
    bold,
    dim,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,

    pub fn code(self: Color) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
        };
    }
};

pub fn color(w: *Writer, c: Color) void {
    w.writeAll(c.code());
}

pub fn bold(w: *Writer, text: []const u8) void {
    w.writeAll(Color.bold.code());
    w.writeAll(text);
    w.writeAll(Color.reset.code());
}

pub fn success(w: *Writer, text: []const u8) void {
    w.writeAll(Color.green.code());
    w.writeAll(text);
    w.writeAll(Color.reset.code());
}

pub fn err(w: *Writer, text: []const u8) void {
    w.writeAll(Color.red.code());
    w.writeAll(text);
    w.writeAll(Color.reset.code());
}

pub fn warn(w: *Writer, text: []const u8) void {
    w.writeAll(Color.yellow.code());
    w.writeAll(text);
    w.writeAll(Color.reset.code());
}

pub fn info(w: *Writer, text: []const u8) void {
    w.writeAll(Color.cyan.code());
    w.writeAll(text);
    w.writeAll(Color.reset.code());
}

pub fn header(w: *Writer, text: []const u8) void {
    w.writeAll("\n");
    bold(w, text);
    w.writeAll("\n");
}

/// Print a key-value pair with aligned formatting.
pub fn kv(w: *Writer, key: []const u8, value: []const u8) void {
    w.writeAll(Color.dim.code());
    w.writeAll(key);
    w.writeAll(Color.reset.code());
    w.writeAll(": ");
    w.writeAll(value);
    w.writeAll("\n");
}

/// Print a table row.
pub fn tableRow(w: *Writer, cols: []const []const u8, widths: []const usize) void {
    for (cols, 0..) |col, i| {
        w.writeAll(col);
        if (i < cols.len - 1) {
            const pad = if (widths[i] > col.len) widths[i] - col.len else 0;
            var j: usize = 0;
            while (j < pad + 2) : (j += 1) {
                w.writeAll(" ");
            }
        }
    }
    w.writeAll("\n");
}
