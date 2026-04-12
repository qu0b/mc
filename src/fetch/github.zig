const std = @import("std");

/// Expand a GitHub shorthand "owner/repo" to a full HTTPS clone URL.
/// If the input already starts with "https://" or "git@", returns it as-is.
pub fn expandRepo(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, repo, "https://") or std.mem.startsWith(u8, repo, "git@")) {
        return allocator.dupe(u8, repo);
    }

    // Ensure .git suffix
    if (std.mem.endsWith(u8, repo, ".git")) {
        return std.fmt.allocPrint(allocator, "https://github.com/{s}", .{repo});
    }
    return std.fmt.allocPrint(allocator, "https://github.com/{s}.git", .{repo});
}

/// Parse a repo spec that might have @ref suffix: "owner/repo@v2.0"
pub fn parseRepoSpec(spec: []const u8) struct { repo: []const u8, ref: ?[]const u8 } {
    // Look for @ but skip the first char (could be scoped npm package)
    if (spec.len > 1) {
        var i: usize = spec.len - 1;
        while (i > 0) : (i -= 1) {
            if (spec[i] == '@') {
                // Make sure this isn't a scope like @org/repo
                if (i > 0 and spec[i - 1] != '/') {
                    return .{ .repo = spec[0..i], .ref = spec[i + 1 ..] };
                }
            }
        }
    }
    return .{ .repo = spec, .ref = null };
}

test "expand github shorthand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const url = try expandRepo(arena.allocator(), "anthropics/claude-plugins-official");
    try std.testing.expectEqualStrings("https://github.com/anthropics/claude-plugins-official.git", url);
}

test "expand already full url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const url = try expandRepo(arena.allocator(), "https://github.com/user/repo.git");
    try std.testing.expectEqualStrings("https://github.com/user/repo.git", url);
}

test "parse repo spec with ref" {
    const result = parseRepoSpec("owner/repo@v2.0");
    try std.testing.expectEqualStrings("owner/repo", result.repo);
    try std.testing.expectEqualStrings("v2.0", result.ref.?);
}

test "parse repo spec without ref" {
    const result = parseRepoSpec("owner/repo");
    try std.testing.expectEqualStrings("owner/repo", result.repo);
    try std.testing.expect(result.ref == null);
}
