const std = @import("std");

pub const Severity = enum { err, warn };

/// A single diagnostic — produced by validation walks.
/// `file` and `path` are borrowed; caller keeps them alive.
/// `message` is owned by the parent `Diagnostics` arena.
pub const Diagnostic = struct {
    file: []const u8,
    path: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
    severity: Severity,
    message: []const u8,
};

/// Accumulator for diagnostics across an entire validation run.
/// Errors and warnings are collected and never abort the walk — callers
/// gate on `hasErrors()` at the end.
pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diagnostic),

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .items = .empty,
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.items.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn err(
        self: *Diagnostics,
        file: []const u8,
        path: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.append(.err, file, path, fmt, args);
    }

    pub fn warn(
        self: *Diagnostics,
        file: []const u8,
        path: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.append(.warn, file, path, fmt, args);
    }

    fn append(
        self: *Diagnostics,
        sev: Severity,
        file: []const u8,
        path: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const msg = try std.fmt.allocPrint(self.arena.allocator(), fmt, args);
        try self.items.append(self.allocator, .{
            .file = file,
            .path = path,
            .severity = sev,
            .message = msg,
        });
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        for (self.items.items) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.items.items.len;
    }

    /// Pretty-print grouped by file, sorted by (file, line, column, path).
    /// Final summary line: `Found N error(s), M warning(s)`.
    pub fn render(self: *const Diagnostics, w: anytype) !void {
        // Copy pointers for sort; keep original order stable in self.
        var sorted = try self.allocator.alloc(*const Diagnostic, self.items.items.len);
        defer self.allocator.free(sorted);
        for (self.items.items, 0..) |*d, i| sorted[i] = d;

        std.sort.pdq(*const Diagnostic, sorted, {}, lessThan);

        var n_err: usize = 0;
        var n_warn: usize = 0;
        for (self.items.items) |d| switch (d.severity) {
            .err => n_err += 1,
            .warn => n_warn += 1,
        };

        // Group by file: header then each entry under it.
        var current_file: ?[]const u8 = null;
        for (sorted) |d| {
            const need_header = current_file == null or !std.mem.eql(u8, current_file.?, d.file);
            if (need_header) {
                if (current_file != null) try w.writeAll("\n");
                const label = switch (d.severity) {
                    .err => "error",
                    .warn => "warning",
                };
                try w.print("{s}: {s}\n", .{ label, d.file });
                current_file = d.file;
            }
            if (d.path.len == 0) {
                try w.print("  └─ {s}\n", .{d.message});
            } else {
                try w.print("  └─ {s}: {s}\n", .{ d.path, d.message });
            }
        }
        if (self.items.items.len > 0) try w.writeAll("\n");
        try w.print(
            "Found {d} {s}, {d} {s}\n",
            .{ n_err, plural("error", n_err), n_warn, plural("warning", n_warn) },
        );
    }
};

fn plural(comptime base: []const u8, n: usize) []const u8 {
    return if (n == 1) base else base ++ "s";
}

fn lessThan(_: void, a: *const Diagnostic, b: *const Diagnostic) bool {
    const f = std.mem.order(u8, a.file, b.file);
    if (f != .eq) return f == .lt;
    // nulls last
    const al = a.line orelse std.math.maxInt(u32);
    const bl = b.line orelse std.math.maxInt(u32);
    if (al != bl) return al < bl;
    const ac = a.column orelse std.math.maxInt(u32);
    const bc = b.column orelse std.math.maxInt(u32);
    if (ac != bc) return ac < bc;
    return std.mem.order(u8, a.path, b.path) == .lt;
}
