const std = @import("std");

/// All source types supported by the Claude Code plugin ecosystem.
/// Resolved from the polymorphic `source` field in marketplace.json.
pub const Source = union(enum) {
    /// Relative local path: "./plugins/frontend-design"
    local: []const u8,
    /// GitHub repo: { "source": "github", "repo": "owner/repo" }
    github: GitHubSource,
    /// Git URL: { "source": "url", "url": "https://..." }
    url: UrlSource,
    /// Git subdirectory (sparse checkout): { "source": "git-subdir", ... }
    git_subdir: GitSubdirSource,
    /// npm package: { "source": "npm", "package": "@scope/name" }
    npm: NpmSource,

    pub fn description(self: Source) []const u8 {
        return switch (self) {
            .local => "local",
            .github => "github",
            .url => "git",
            .git_subdir => "git-subdir",
            .npm => "npm",
        };
    }
};

pub const GitHubSource = struct {
    repo: []const u8,
    ref: ?[]const u8 = null,
    sha: ?[]const u8 = null,
};

pub const UrlSource = struct {
    url: []const u8,
    ref: ?[]const u8 = null,
    sha: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const GitSubdirSource = struct {
    url: []const u8,
    path: []const u8,
    ref: ?[]const u8 = null,
    sha: ?[]const u8 = null,
};

pub const NpmSource = struct {
    package: []const u8,
    version: ?[]const u8 = null,
    registry: ?[]const u8 = null,
};

/// Resolve a `std.json.Value` (from marketplace.json's polymorphic source field)
/// into a typed Source. The Value can be a string (local path) or an object.
pub fn resolveSource(value: std.json.Value) !Source {
    switch (value) {
        .string => |s| return .{ .local = s },
        .object => |obj| {
            const source_type = obj.get("source") orelse return error.MissingSourceType;
            const st = switch (source_type) {
                .string => |s| s,
                else => return error.InvalidSourceType,
            };

            if (std.mem.eql(u8, st, "github")) {
                return .{ .github = .{
                    .repo = getString(obj, "repo") orelse return error.MissingRepo,
                    .ref = getString(obj, "ref"),
                    .sha = getString(obj, "sha"),
                } };
            } else if (std.mem.eql(u8, st, "url")) {
                return .{ .url = .{
                    .url = getString(obj, "url") orelse return error.MissingUrl,
                    .ref = getString(obj, "ref"),
                    .sha = getString(obj, "sha"),
                    .path = getString(obj, "path"),
                } };
            } else if (std.mem.eql(u8, st, "git-subdir")) {
                return .{ .git_subdir = .{
                    .url = getString(obj, "url") orelse return error.MissingUrl,
                    .path = getString(obj, "path") orelse return error.MissingPath,
                    .ref = getString(obj, "ref"),
                    .sha = getString(obj, "sha"),
                } };
            } else if (std.mem.eql(u8, st, "npm")) {
                return .{ .npm = .{
                    .package = getString(obj, "package") orelse return error.MissingPackage,
                    .version = getString(obj, "version"),
                    .registry = getString(obj, "registry"),
                } };
            }

            return error.UnknownSourceType;
        },
        else => return error.InvalidSourceFormat,
    }
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

test "resolve local source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = std.json.Value{ .string = "./plugins/frontend-design" };
    const src = try resolveSource(val);
    try std.testing.expectEqualStrings("./plugins/frontend-design", src.local);
}

test "resolve github source" {
    // Build a json object manually
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var obj = std.json.ObjectMap.init(arena.allocator());
    try obj.put("source", .{ .string = "github" });
    try obj.put("repo", .{ .string = "anthropics/claude-plugins-official" });
    try obj.put("sha", .{ .string = "abc123" });

    const src = try resolveSource(.{ .object = obj });
    try std.testing.expectEqualStrings("anthropics/claude-plugins-official", src.github.repo);
    try std.testing.expectEqualStrings("abc123", src.github.sha.?);
}
