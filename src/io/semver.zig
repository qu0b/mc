const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre: ?[]const u8 = null,

    pub fn parse(s: []const u8) !Version {
        var input = s;
        // Strip leading 'v' if present
        if (input.len > 0 and input[0] == 'v') input = input[1..];

        const major_end = std.mem.indexOfScalar(u8, input, '.') orelse return error.InvalidVersion;
        const major = try std.fmt.parseInt(u32, input[0..major_end], 10);
        input = input[major_end + 1 ..];

        const minor_end = std.mem.indexOfScalar(u8, input, '.') orelse {
            // Allow "1.0" format (no patch)
            const pre_start = std.mem.indexOfScalar(u8, input, '-');
            if (pre_start) |ps| {
                return .{
                    .major = major,
                    .minor = try std.fmt.parseInt(u32, input[0..ps], 10),
                    .patch = 0,
                    .pre = input[ps + 1 ..],
                };
            }
            return .{
                .major = major,
                .minor = try std.fmt.parseInt(u32, input, 10),
                .patch = 0,
            };
        };
        const minor = try std.fmt.parseInt(u32, input[0..minor_end], 10);
        input = input[minor_end + 1 ..];

        const pre_start = std.mem.indexOfScalar(u8, input, '-');
        if (pre_start) |ps| {
            return .{
                .major = major,
                .minor = minor,
                .patch = try std.fmt.parseInt(u32, input[0..ps], 10),
                .pre = input[ps + 1 ..],
            };
        }

        return .{
            .major = major,
            .minor = minor,
            .patch = try std.fmt.parseInt(u32, input, 10),
        };
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.patch != b.patch) return std.math.order(a.patch, b.patch);
        // Pre-release < release
        if (a.pre != null and b.pre == null) return .lt;
        if (a.pre == null and b.pre != null) return .gt;
        return .eq;
    }

    pub fn format(self: Version, buf: []u8) ![]const u8 {
        if (self.pre) |pre| {
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}-{s}", .{ self.major, self.minor, self.patch, pre });
        }
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
    }
};

/// A version constraint like ^1.0.0, ~1.2.0, >=1.0.0, or exact 1.2.3
pub const Constraint = struct {
    op: Op,
    version: Version,

    pub const Op = enum {
        exact, // 1.2.3
        caret, // ^1.2.3 (compatible with)
        tilde, // ~1.2.3 (approximately)
        gte, // >=1.2.3
        gt, // >1.2.3
        lte, // <=1.2.3
        lt, // <1.2.3
    };

    pub fn parse(s: []const u8) !Constraint {
        if (s.len == 0) return error.InvalidConstraint;

        if (s[0] == '^') return .{ .op = .caret, .version = try Version.parse(s[1..]) };
        if (s[0] == '~') return .{ .op = .tilde, .version = try Version.parse(s[1..]) };
        if (std.mem.startsWith(u8, s, ">=")) return .{ .op = .gte, .version = try Version.parse(s[2..]) };
        if (std.mem.startsWith(u8, s, "<=")) return .{ .op = .lte, .version = try Version.parse(s[2..]) };
        if (s[0] == '>') return .{ .op = .gt, .version = try Version.parse(s[1..]) };
        if (s[0] == '<') return .{ .op = .lt, .version = try Version.parse(s[1..]) };

        return .{ .op = .exact, .version = try Version.parse(s) };
    }

    /// Check if a version satisfies this constraint.
    pub fn matches(self: Constraint, v: Version) bool {
        return switch (self.op) {
            .exact => v.order(self.version) == .eq,
            .gte => v.order(self.version) != .lt,
            .gt => v.order(self.version) == .gt,
            .lte => v.order(self.version) != .gt,
            .lt => v.order(self.version) == .lt,
            .caret => blk: {
                // ^1.2.3 := >=1.2.3 <2.0.0
                // ^0.2.3 := >=0.2.3 <0.3.0
                // ^0.0.3 := >=0.0.3 <0.0.4
                if (v.order(self.version) == .lt) break :blk false;
                if (self.version.major != 0) {
                    break :blk v.major == self.version.major;
                } else if (self.version.minor != 0) {
                    break :blk v.major == 0 and v.minor == self.version.minor;
                } else {
                    break :blk v.major == 0 and v.minor == 0 and v.patch == self.version.patch;
                }
            },
            .tilde => blk: {
                // ~1.2.3 := >=1.2.3 <1.3.0
                if (v.order(self.version) == .lt) break :blk false;
                break :blk v.major == self.version.major and v.minor == self.version.minor;
            },
        };
    }
};

test "parse version" {
    const v = try Version.parse("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 2), v.minor);
    try std.testing.expectEqual(@as(u32, 3), v.patch);
    try std.testing.expect(v.pre == null);
}

test "parse version with v prefix" {
    const v = try Version.parse("v2.0.0");
    try std.testing.expectEqual(@as(u32, 2), v.major);
}

test "parse version with pre-release" {
    const v = try Version.parse("1.0.0-beta.1");
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqualStrings("beta.1", v.pre.?);
}

test "version ordering" {
    const v1 = try Version.parse("1.0.0");
    const v2 = try Version.parse("2.0.0");
    const v1_1 = try Version.parse("1.1.0");
    const v1_pre = try Version.parse("1.0.0-alpha");

    try std.testing.expect(v1.order(v2) == .lt);
    try std.testing.expect(v1.order(v1_1) == .lt);
    try std.testing.expect(v1_pre.order(v1) == .lt);
}

test "caret constraint" {
    const c = try Constraint.parse("^1.2.0");
    try std.testing.expect(c.matches(try Version.parse("1.2.0")));
    try std.testing.expect(c.matches(try Version.parse("1.9.9")));
    try std.testing.expect(!c.matches(try Version.parse("2.0.0")));
    try std.testing.expect(!c.matches(try Version.parse("1.1.0")));
}

test "tilde constraint" {
    const c = try Constraint.parse("~1.2.0");
    try std.testing.expect(c.matches(try Version.parse("1.2.0")));
    try std.testing.expect(c.matches(try Version.parse("1.2.9")));
    try std.testing.expect(!c.matches(try Version.parse("1.3.0")));
}
