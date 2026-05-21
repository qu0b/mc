// Minimal SemVer 2.0 parser + range matcher for mc.
//
// Supported operators:  exact, ^, ~, >=, <
// Supported grammar:    MAJOR.MINOR.PATCH[-PRE][+BUILD]   (all three numeric parts required)
//
// Deliberate limitations / decisions:
//   * Two-part ranges like `^0.14` are REJECTED with InvalidRange. All ranges
//     must spell out major.minor.patch.
//   * A leading `v` prefix on versions (e.g. `v1.2.3`) is REJECTED.
//   * Whitespace between the operator and version (e.g. `>= 1.2.3`) is
//     accepted; outer whitespace on both range and version strings is trimmed.
//   * Build metadata (after `+`) is parsed-and-discarded per SemVer spec
//     (ignored in all comparisons).
//   * Ranges do not implicitly include prereleases. A prerelease version only
//     satisfies a range if the range's own version also carries a prerelease.
//     (Stricter than NPM — documented as known limitation for v1.)

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    pre: ?[]const u8 = null,

    /// Total order on versions per SemVer 2.0 §11.
    /// Build metadata is ignored. Prerelease versions sort BEFORE their
    /// corresponding release (`1.0.0-rc.1` < `1.0.0`).
    pub fn compare(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.patch != b.patch) return std.math.order(a.patch, b.patch);
        // §11: a version WITHOUT prerelease > a version WITH one.
        if (a.pre == null and b.pre == null) return .eq;
        if (a.pre == null) return .gt;
        if (b.pre == null) return .lt;
        return comparePre(a.pre.?, b.pre.?);
    }

    pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        if (self.pre) |pre| try writer.print("-{s}", .{pre});
    }
};

pub const Operator = enum {
    exact, // "1.2.3"
    caret, // "^1.2.3" — NPM semantics
    tilde, // "~1.2.3"
    gte, //   ">=1.2.3"
    lt, //    "<1.2.3"
};

pub const Range = struct {
    op: Operator,
    version: Version,
};

pub const ParseError = error{
    InvalidVersion,
    InvalidRange,
    EmptyString,
    OutOfMemory,
} || std.fmt.ParseIntError;

/// Parse "MAJOR.MINOR.PATCH[-PRE][+BUILD]". All three numeric parts required.
pub fn parseVersion(s: []const u8) ParseError!Version {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return error.EmptyString;

    // Strip build metadata (ignored per spec).
    var core_and_pre = trimmed;
    if (std.mem.indexOfScalar(u8, core_and_pre, '+')) |plus| {
        if (plus == core_and_pre.len - 1) return error.InvalidVersion; // empty build
        core_and_pre = core_and_pre[0..plus];
    }

    // Split prerelease.
    var core_str = core_and_pre;
    var pre: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, core_and_pre, '-')) |dash| {
        core_str = core_and_pre[0..dash];
        const pre_str = core_and_pre[dash + 1 ..];
        if (pre_str.len == 0) return error.InvalidVersion;
        if (!isValidPrerelease(pre_str)) return error.InvalidVersion;
        pre = pre_str;
    }

    // Split core into exactly three parts.
    var it = std.mem.splitScalar(u8, core_str, '.');
    const major_s = it.next() orelse return error.InvalidVersion;
    const minor_s = it.next() orelse return error.InvalidVersion;
    const patch_s = it.next() orelse return error.InvalidVersion;
    if (it.next() != null) return error.InvalidVersion; // 4+ parts

    if (major_s.len == 0 or minor_s.len == 0 or patch_s.len == 0) {
        return error.InvalidVersion;
    }
    // Reject leading 'v' and any other non-digit.
    for ([_][]const u8{ major_s, minor_s, patch_s }) |part| {
        for (part) |c| if (c < '0' or c > '9') return error.InvalidVersion;
    }

    return .{
        .major = try std.fmt.parseInt(u32, major_s, 10),
        .minor = try std.fmt.parseInt(u32, minor_s, 10),
        .patch = try std.fmt.parseInt(u32, patch_s, 10),
        .pre = pre,
    };
}

/// Parse a single range expression. Leading operator (if any) recognized.
/// Whitespace between operator and version allowed. Bare "1.2.3" → .exact.
pub fn parseRange(s: []const u8) ParseError!Range {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return error.EmptyString;

    const op: Operator, const rest: []const u8 = blk: {
        if (std.mem.startsWith(u8, trimmed, ">=")) break :blk .{ .gte, trimmed[2..] };
        if (trimmed[0] == '<') break :blk .{ .lt, trimmed[1..] };
        if (trimmed[0] == '^') break :blk .{ .caret, trimmed[1..] };
        if (trimmed[0] == '~') break :blk .{ .tilde, trimmed[1..] };
        break :blk .{ .exact, trimmed };
    };

    const version = parseVersion(rest) catch |err| switch (err) {
        error.EmptyString => return error.InvalidRange,
        error.InvalidVersion => return error.InvalidRange,
        else => return err,
    };
    return .{ .op = op, .version = version };
}

/// Match a parsed Version against a parsed Range (no allocation).
pub fn matches(v: Version, r: Range) bool {
    return switch (r.op) {
        .exact => v.compare(r.version) == .eq,
        .gte => v.compare(r.version) != .lt,
        .lt => v.compare(r.version) == .lt,
        .caret => caretMatches(v, r.version),
        .tilde => tildeMatches(v, r.version),
    };
}

/// Convenience: parse both and match.
pub fn satisfies(version_str: []const u8, range_str: []const u8) ParseError!bool {
    const v = try parseVersion(version_str);
    const r = try parseRange(range_str);
    return matches(v, r);
}

// -------- internals --------

fn caretMatches(v: Version, base: Version) bool {
    if (v.compare(base) == .lt) return false;
    if (base.major != 0) {
        // ^1.2.3 := >=1.2.3 <2.0.0
        return v.major == base.major;
    }
    if (base.minor != 0) {
        // ^0.2.3 := >=0.2.3 <0.3.0
        return v.major == 0 and v.minor == base.minor;
    }
    // ^0.0.3 := =0.0.3 (same patch)
    return v.major == 0 and v.minor == 0 and v.patch == base.patch;
}

fn tildeMatches(v: Version, base: Version) bool {
    if (v.compare(base) == .lt) return false;
    // ~1.2.3 := >=1.2.3 <1.3.0
    return v.major == base.major and v.minor == base.minor;
}

/// SemVer 2.0 §9: prerelease identifiers are [0-9A-Za-z-] separated by dots,
/// each identifier non-empty, numeric identifiers have no leading zeros.
fn isValidPrerelease(pre: []const u8) bool {
    var it = std.mem.splitScalar(u8, pre, '.');
    while (it.next()) |ident| {
        if (ident.len == 0) return false;
        var all_digits = true;
        for (ident) |c| {
            const is_digit = c >= '0' and c <= '9';
            const is_alpha = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
            if (!(is_digit or is_alpha or c == '-')) return false;
            if (!is_digit) all_digits = false;
        }
        if (all_digits and ident.len > 1 and ident[0] == '0') return false;
    }
    return true;
}

/// SemVer 2.0 §11 prerelease comparison.
fn comparePre(a: []const u8, b: []const u8) std.math.Order {
    var it_a = std.mem.splitScalar(u8, a, '.');
    var it_b = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const id_a = it_a.next();
        const id_b = it_b.next();
        if (id_a == null and id_b == null) return .eq;
        // A smaller set of fields takes precedence IFF all preceding fields are equal.
        if (id_a == null) return .lt;
        if (id_b == null) return .gt;

        const num_a = std.fmt.parseInt(u64, id_a.?, 10) catch null;
        const num_b = std.fmt.parseInt(u64, id_b.?, 10) catch null;
        if (num_a != null and num_b != null) {
            const ord = std.math.order(num_a.?, num_b.?);
            if (ord != .eq) return ord;
        } else if (num_a != null) {
            // numeric < alphanumeric
            return .lt;
        } else if (num_b != null) {
            return .gt;
        } else {
            const ord = std.mem.order(u8, id_a.?, id_b.?);
            if (ord != .eq) return ord;
        }
    }
}

// Inline smoke tests; full coverage lives in tests/io/semver_test.zig.
test "smoke: parse + satisfies" {
    try std.testing.expect(try satisfies("1.2.3", "^1.2.0"));
    try std.testing.expect(!try satisfies("2.0.0", "^1.2.0"));
}
