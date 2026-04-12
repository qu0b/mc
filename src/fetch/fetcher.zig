const std = @import("std");
const compat = @import("../io/compat.zig");
const source_mod = @import("../schema/source.zig");
const git_mod = @import("git.zig");
const github_mod = @import("github.zig");
const local_mod = @import("local.zig");
const cache_store = @import("../cache/store.zig");
const cache_index = @import("../cache/index.zig");
const hash_mod = @import("../io/hash.zig");

pub const FetchResult = struct {
    content_hash: []const u8,
    install_path: []const u8,
    git_sha: ?[]const u8 = null,
};

/// Fetch a plugin from its source, store in content-addressed cache,
/// and link to the install directory.
pub fn fetch(
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    plugin_name: []const u8,
    marketplace_name: []const u8,
    marketplace_path: ?[]const u8,
    install_dir: []const u8,
) !FetchResult {
    var store = try cache_store.ContentStore.init(allocator);

    // Create a temp directory for fetching
    const tmp_base = try std.fmt.allocPrint(allocator, "/tmp/mc-fetch-{s}", .{plugin_name});
    compat.deleteTreeAbsolute(tmp_base);
    try compat.makeDirAbsolute(tmp_base);
    defer compat.deleteTreeAbsolute(tmp_base);

    var git_sha: ?[]const u8 = null;
    var source_dir: []const u8 = undefined;

    switch (source) {
        .local => |path| {
            // Resolve relative to marketplace root
            const base = marketplace_path orelse return error.NoMarketplacePath;
            source_dir = try local_mod.resolvePath(allocator, base, path);
        },
        .github => |gh| {
            const url = try github_mod.expandRepo(allocator, gh.repo);
            try git_mod.clone(allocator, url, tmp_base, gh.ref);
            if (gh.sha) |sha| {
                try git_mod.checkoutSha(allocator, tmp_base, sha);
                git_sha = sha;
            } else {
                git_sha = git_mod.getHeadSha(allocator, tmp_base) catch null;
            }
            source_dir = tmp_base;
        },
        .url => |u| {
            const url_str = if (std.mem.endsWith(u8, u.url, ".git") or
                std.mem.indexOf(u8, u.url, "github.com") != null or
                std.mem.indexOf(u8, u.url, "gitlab.com") != null)
                u.url
            else
                u.url;

            try git_mod.clone(allocator, url_str, tmp_base, u.ref);
            if (u.sha) |sha| {
                try git_mod.checkoutSha(allocator, tmp_base, sha);
                git_sha = sha;
            } else {
                git_sha = git_mod.getHeadSha(allocator, tmp_base) catch null;
            }
            // If path is specified, use that subdirectory
            if (u.path) |subpath| {
                source_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_base, subpath });
            } else {
                source_dir = tmp_base;
            }
        },
        .git_subdir => |gs| {
            const url = try github_mod.expandRepo(allocator, gs.url);
            try git_mod.sparseCheckout(allocator, url, gs.path, tmp_base, gs.ref);
            if (gs.sha) |sha| {
                try git_mod.checkoutSha(allocator, tmp_base, sha);
                git_sha = sha;
            } else {
                git_sha = git_mod.getHeadSha(allocator, tmp_base) catch null;
            }
            source_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_base, gs.path });
        },
        .npm => {
            return error.NpmNotImplemented;
        },
    }

    // Store in content-addressed cache
    const content_hash = try store.store(allocator, source_dir);

    // Link to install directory
    const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ install_dir, plugin_name });
    try store.link(allocator, content_hash, target);

    // Update cache index
    cache_index.addEntry(allocator, content_hash, .{
        .name = plugin_name,
        .marketplace = marketplace_name,
        .version = "latest",
        .fetched_at = "now",
        .source_type = source.description(),
    }) catch {};

    return .{
        .content_hash = content_hash,
        .install_path = target,
        .git_sha = git_sha,
    };
}
