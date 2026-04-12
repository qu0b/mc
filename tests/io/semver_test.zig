const std = @import("std");
const semver = @import("mc").io.semver;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

// ---------------- parseVersion ----------------

test "parseVersion: basic" {
    const v = try semver.parseVersion("1.2.3");
    try expectEqual(@as(u32, 1), v.major);
    try expectEqual(@as(u32, 2), v.minor);
    try expectEqual(@as(u32, 3), v.patch);
    try expect(v.pre == null);
}

test "parseVersion: zeros" {
    const v = try semver.parseVersion("0.0.0");
    try expectEqual(@as(u32, 0), v.major);
    try expectEqual(@as(u32, 0), v.minor);
    try expectEqual(@as(u32, 0), v.patch);
}

test "parseVersion: multi-digit" {
    const v = try semver.parseVersion("10.20.30");
    try expectEqual(@as(u32, 10), v.major);
    try expectEqual(@as(u32, 20), v.minor);
    try expectEqual(@as(u32, 30), v.patch);
}

test "parseVersion: prerelease simple" {
    const v = try semver.parseVersion("1.2.3-rc.1");
    try expectEqual(@as(u32, 1), v.major);
    try expectEqualStrings("rc.1", v.pre.?);
}

test "parseVersion: prerelease alpha" {
    const v = try semver.parseVersion("1.0.0-alpha");
    try expectEqualStrings("alpha", v.pre.?);
}

test "parseVersion: build metadata discarded" {
    const v = try semver.parseVersion("1.2.3+build.1");
    try expectEqual(@as(u32, 3), v.patch);
    try expect(v.pre == null);
}

test "parseVersion: prerelease + build metadata" {
    const v = try semver.parseVersion("1.2.3-beta.2+sha.abc");
    try expectEqualStrings("beta.2", v.pre.?);
}

test "parseVersion: rejects two parts" {
    try expectError(error.InvalidVersion, semver.parseVersion("1.2"));
}

test "parseVersion: rejects four parts" {
    try expectError(error.InvalidVersion, semver.parseVersion("1.2.3.4"));
}

test "parseVersion: rejects v prefix" {
    try expectError(error.InvalidVersion, semver.parseVersion("v1.2.3"));
}

test "parseVersion: rejects empty" {
    try expectError(error.EmptyString, semver.parseVersion(""));
    try expectError(error.EmptyString, semver.parseVersion("   "));
}

test "parseVersion: rejects empty part" {
    try expectError(error.InvalidVersion, semver.parseVersion("1..3"));
    try expectError(error.InvalidVersion, semver.parseVersion(".2.3"));
    try expectError(error.InvalidVersion, semver.parseVersion("1.2."));
}

test "parseVersion: rejects non-numeric core" {
    try expectError(error.InvalidVersion, semver.parseVersion("1.a.3"));
    try expectError(error.InvalidVersion, semver.parseVersion("1.2.x"));
}

test "parseVersion: rejects empty prerelease" {
    try expectError(error.InvalidVersion, semver.parseVersion("1.2.3-"));
}

test "parseVersion: rejects empty prerelease identifier" {
    try expectError(error.InvalidVersion, semver.parseVersion("1.2.3-rc..1"));
}

test "parseVersion: rejects empty build" {
    try expectError(error.InvalidVersion, semver.parseVersion("1.2.3+"));
}

test "parseVersion: trims whitespace" {
    const v = try semver.parseVersion("  1.2.3  ");
    try expectEqual(@as(u32, 2), v.minor);
}

// ---------------- Version.compare ----------------

test "compare: basic ordering" {
    const a = try semver.parseVersion("1.0.0");
    const b = try semver.parseVersion("2.0.0");
    try expect(a.compare(b) == .lt);
    try expect(b.compare(a) == .gt);
    try expect(a.compare(a) == .eq);
}

test "compare: minor/patch precedence" {
    const a = try semver.parseVersion("1.2.0");
    const b = try semver.parseVersion("1.3.0");
    const c = try semver.parseVersion("1.2.5");
    try expect(a.compare(b) == .lt);
    try expect(a.compare(c) == .lt);
    try expect(b.compare(c) == .gt);
}

test "compare: prerelease is less than release" {
    const rel = try semver.parseVersion("1.0.0");
    const pre = try semver.parseVersion("1.0.0-rc.1");
    try expect(pre.compare(rel) == .lt);
    try expect(rel.compare(pre) == .gt);
}

test "compare: prerelease chain per §11" {
    // 1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-beta < 1.0.0-rc.1 < 1.0.0
    const a = try semver.parseVersion("1.0.0-alpha");
    const b = try semver.parseVersion("1.0.0-alpha.1");
    const c = try semver.parseVersion("1.0.0-beta");
    const d = try semver.parseVersion("1.0.0-rc.1");
    const e = try semver.parseVersion("1.0.0");
    try expect(a.compare(b) == .lt);
    try expect(b.compare(c) == .lt);
    try expect(c.compare(d) == .lt);
    try expect(d.compare(e) == .lt);
}

test "compare: numeric identifiers compared numerically" {
    const a = try semver.parseVersion("1.0.0-alpha.2");
    const b = try semver.parseVersion("1.0.0-alpha.10");
    try expect(a.compare(b) == .lt); // 2 < 10 numerically, not lexically
}

test "compare: numeric < alphanumeric identifier" {
    // Per §11: numeric identifiers always have lower precedence than alphanumeric.
    const a = try semver.parseVersion("1.0.0-alpha.1");
    const b = try semver.parseVersion("1.0.0-alpha.beta");
    try expect(a.compare(b) == .lt);
}

test "compare: fewer prerelease fields < more fields" {
    const a = try semver.parseVersion("1.0.0-alpha");
    const b = try semver.parseVersion("1.0.0-alpha.1");
    try expect(a.compare(b) == .lt);
}

test "compare: build metadata ignored" {
    const a = try semver.parseVersion("1.0.0+build.1");
    const b = try semver.parseVersion("1.0.0+build.99");
    try expect(a.compare(b) == .eq);
}

// ---------------- Version.format ----------------

test "format: without prerelease" {
    const v = try semver.parseVersion("1.2.3");
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{}", .{v});
    try expectEqualStrings("1.2.3", s);
}

test "format: with prerelease" {
    const v = try semver.parseVersion("1.2.3-rc.1");
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{}", .{v});
    try expectEqualStrings("1.2.3-rc.1", s);
}

// ---------------- parseRange ----------------

test "parseRange: exact (bare)" {
    const r = try semver.parseRange("1.2.3");
    try expect(r.op == .exact);
    try expectEqual(@as(u32, 3), r.version.patch);
}

test "parseRange: caret" {
    const r = try semver.parseRange("^1.2.3");
    try expect(r.op == .caret);
}

test "parseRange: tilde" {
    const r = try semver.parseRange("~1.2.3");
    try expect(r.op == .tilde);
}

test "parseRange: gte" {
    const r = try semver.parseRange(">=1.2.3");
    try expect(r.op == .gte);
}

test "parseRange: lt" {
    const r = try semver.parseRange("<1.2.3");
    try expect(r.op == .lt);
}

test "parseRange: whitespace after operator accepted" {
    const r = try semver.parseRange(">= 1.2.3");
    try expect(r.op == .gte);
    try expectEqual(@as(u32, 3), r.version.patch);
}

test "parseRange: outer whitespace trimmed" {
    const r = try semver.parseRange("  ^1.2.3  ");
    try expect(r.op == .caret);
}

test "parseRange: two-part version rejected" {
    try expectError(error.InvalidRange, semver.parseRange("^0.14"));
    try expectError(error.InvalidRange, semver.parseRange("~1.2"));
    try expectError(error.InvalidRange, semver.parseRange("1.2"));
}

test "parseRange: empty rejected" {
    try expectError(error.EmptyString, semver.parseRange(""));
}

test "parseRange: invalid version inside range" {
    try expectError(error.InvalidRange, semver.parseRange("^vXYZ"));
    try expectError(error.InvalidRange, semver.parseRange(">=garbage"));
}

// ---------------- satisfies: the spec table ----------------

test "satisfies exact: 1.2.3" {
    try expect(try semver.satisfies("1.2.3", "1.2.3"));
    try expect(!try semver.satisfies("1.2.4", "1.2.3"));
    try expect(!try semver.satisfies("1.2.3-rc.1", "1.2.3"));
    try expect(!try semver.satisfies("1.2.2", "1.2.3"));
}

test "satisfies caret: ^1.2.3" {
    try expect(try semver.satisfies("1.2.3", "^1.2.3"));
    try expect(try semver.satisfies("1.2.4", "^1.2.3"));
    try expect(try semver.satisfies("1.9.9", "^1.2.3"));
    try expect(!try semver.satisfies("2.0.0", "^1.2.3"));
    try expect(!try semver.satisfies("1.2.2", "^1.2.3"));
    try expect(!try semver.satisfies("0.9.9", "^1.2.3"));
}

test "satisfies caret 0.x: ^0.2.3" {
    try expect(try semver.satisfies("0.2.3", "^0.2.3"));
    try expect(try semver.satisfies("0.2.9", "^0.2.3"));
    try expect(!try semver.satisfies("0.3.0", "^0.2.3"));
    try expect(!try semver.satisfies("0.2.2", "^0.2.3"));
    try expect(!try semver.satisfies("1.0.0", "^0.2.3"));
}

test "satisfies caret 0.0.x: ^0.0.3" {
    try expect(try semver.satisfies("0.0.3", "^0.0.3"));
    try expect(!try semver.satisfies("0.0.4", "^0.0.3"));
    try expect(!try semver.satisfies("0.0.2", "^0.0.3"));
    try expect(!try semver.satisfies("0.1.0", "^0.0.3"));
}

test "satisfies tilde: ~1.2.3" {
    try expect(try semver.satisfies("1.2.3", "~1.2.3"));
    try expect(try semver.satisfies("1.2.99", "~1.2.3"));
    try expect(!try semver.satisfies("1.3.0", "~1.2.3"));
    try expect(!try semver.satisfies("1.2.2", "~1.2.3"));
    try expect(!try semver.satisfies("2.0.0", "~1.2.3"));
}

test "satisfies gte: >=1.2.3" {
    try expect(try semver.satisfies("1.2.3", ">=1.2.3"));
    try expect(try semver.satisfies("1.2.4", ">=1.2.3"));
    try expect(try semver.satisfies("99.0.0", ">=1.2.3"));
    try expect(!try semver.satisfies("1.2.2", ">=1.2.3"));
    try expect(!try semver.satisfies("0.9.9", ">=1.2.3"));
}

test "satisfies lt: <2.0.0" {
    try expect(try semver.satisfies("1.99.99", "<2.0.0"));
    try expect(try semver.satisfies("0.0.1", "<2.0.0"));
    try expect(!try semver.satisfies("2.0.0", "<2.0.0"));
    try expect(!try semver.satisfies("2.0.1", "<2.0.0"));
}

test "satisfies: prerelease does not satisfy plain range" {
    // Known limitation documented in module header.
    try expect(!try semver.satisfies("1.2.3-rc.1", "^1.2.3"));
    try expect(!try semver.satisfies("1.2.3-rc.1", "1.2.3"));
}

test "satisfies: prerelease range matches matching prerelease" {
    try expect(try semver.satisfies("1.2.3-rc.1", "1.2.3-rc.1"));
}

// ---------------- matches (no-alloc) ----------------

test "matches: direct Range+Version" {
    const v = try semver.parseVersion("1.5.0");
    const r = try semver.parseRange("^1.2.3");
    try expect(semver.matches(v, r));
}
