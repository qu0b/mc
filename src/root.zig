// mc -- Zero-Copy Package Manager for Coding Assistants
//
// Library root. Re-exports all public modules.

pub const io = struct {
    pub const compat = @import("io/compat.zig");
    pub const mmap = @import("io/mmap.zig");
    pub const json = @import("io/json.zig");
    pub const writer = @import("io/writer.zig");
    pub const hash = @import("io/hash.zig");
    pub const semver = @import("io/semver.zig");
    // diagnostic / json_strict are wired into build.zig as separate test
    // modules (they import each other by module name, which the root.zig
    // test module does not provide).
};

pub const schema = struct {
    pub const source = @import("schema/source.zig");
    pub const marketplace = @import("schema/marketplace.zig");
    pub const plugin = @import("schema/plugin.zig");
    pub const mcp = @import("schema/mcp.zig");
    pub const lsp = @import("schema/lsp.zig");
    pub const hooks = @import("schema/hooks.zig");
};

pub const core = struct {
    pub const manifest = @import("core/manifest.zig");
    pub const lockfile = @import("core/lockfile.zig");
    pub const sandbox = @import("core/sandbox.zig");
    pub const resolver = @import("core/resolver.zig");
    pub const config = @import("core/config.zig");
};

pub const fetch = struct {
    pub const fetcher = @import("fetch/fetcher.zig");
    pub const git = @import("fetch/git.zig");
    pub const github = @import("fetch/github.zig");
    pub const http = @import("fetch/http.zig");
    pub const local = @import("fetch/local.zig");
};

pub const cache = struct {
    pub const store = @import("cache/store.zig");
    pub const index = @import("cache/index.zig");
};

test {
    // Pull in all tests from all modules
    @import("std").testing.refAllDecls(@This());
}
