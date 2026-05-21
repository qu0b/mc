const std = @import("std");
const compat = @import("iocompat");

pub const GitError = error{
    GitNotFound,
    CloneFailed,
    CheckoutFailed,
    SparseCheckoutFailed,
    PullFailed,
};

/// Clone a git repository to target_dir.
pub fn clone(allocator: std.mem.Allocator, url: []const u8, target_dir: []const u8, ref: ?[]const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(allocator, &.{ "git", "clone", "--depth", "1", "--single-branch" });

    if (ref) |r| {
        try args.appendSlice(allocator, &.{ "--branch", r });
    }

    try args.appendSlice(allocator, &.{ url, target_dir });

    try runGit(args.items);
}

/// Sparse-checkout a subdirectory from a git repo.
pub fn sparseCheckout(
    allocator: std.mem.Allocator,
    url: []const u8,
    subpath: []const u8,
    target_dir: []const u8,
    ref: ?[]const u8,
) !void {
    _ = allocator;

    // Clone with no checkout, blob filter
    try runGit(&.{
        "git", "clone", "--filter=blob:none", "--no-checkout", url, target_dir,
    });

    // Set sparse-checkout
    try runGit(&.{
        "git", "-C", target_dir, "sparse-checkout", "set", subpath,
    });

    // Checkout
    const checkout_ref = ref orelse "HEAD";
    try runGit(&.{
        "git", "-C", target_dir, "checkout", checkout_ref,
    });
}

/// Checkout a specific commit SHA.
pub fn checkoutSha(allocator: std.mem.Allocator, repo_dir: []const u8, sha: []const u8) !void {
    _ = allocator;
    try runGit(&.{
        "git", "-C", repo_dir, "checkout", sha,
    });
}

/// Pull latest changes in a repository.
pub fn pull(allocator: std.mem.Allocator, repo_dir: []const u8) !void {
    _ = allocator;
    try runGit(&.{
        "git", "-C", repo_dir, "pull", "--ff-only",
    });
}

/// Get the current HEAD commit SHA.
pub fn getHeadSha(allocator: std.mem.Allocator, repo_dir: []const u8) ![]const u8 {
    const result = try compat.runCommandOutput(allocator, &.{
        "git", "-C", repo_dir, "rev-parse", "HEAD",
    });
    if (result.code != 0) return error.CloneFailed;
    return result.out;
}

fn runGit(args: []const []const u8) !void {
    const code = try compat.runCommand(args);
    if (code != 0) {
        return error.CloneFailed;
    }
}
