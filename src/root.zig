//! # mc — agent configuration & package management, as a library
//!
//! `mc` is the engine behind the `mc` CLI. It is also a plain Zig library: add
//! it as a dependency and `@import("mc")` to reuse any of these pieces.
//!
//! The headline capability is the **cross-runtime agent configuration
//! superset**: parse one `agent.json` (`schema.agent`) and emit native config
//! for Claude Managed Agents, OpenClaw, Hermes, or Pi (`core.emit`). See
//! `docs/agent-config-superset.md`.
//!
//! ## Quick taste
//! ```zig
//! const mc = @import("mc");
//! var diags = mc.io.diagnostic.Diagnostics.init(allocator);
//! defer diags.deinit();
//! const agent = (try mc.schema.agent.parseAgent(allocator, "agent.json", src, &diags)).?;
//! const claude_json = try mc.core.emit.emitClaude(allocator, agent, prompt_text);
//! ```
//!
//! Namespaces: `io` (parsing/IO primitives), `schema` (config file schemas),
//! `core` (resolution, materialization, emitters), `fetch` (plugin sources),
//! `cache` (content-addressed store).

/// Low-level IO, parsing and diagnostics primitives.
pub const io = struct {
    /// Zig 0.16 filesystem / process / time compatibility shim.
    pub const compat = @import("iocompat");
    pub const mmap = @import("mmap");
    pub const json = @import("json");
    pub const writer = @import("io/writer.zig");
    pub const hash = @import("io/hash.zig");
    /// Semantic-version parsing & range matching.
    pub const semver = @import("semver");
    /// Accumulating, non-aborting validation diagnostics.
    pub const diagnostic = @import("diagnostic");
    /// Declarative strict-JSON schema validator (`FieldSpec`).
    pub const json_strict = @import("json_strict");
};

/// Strict schemas for every config file `mc` understands.
pub const schema = struct {
    /// The cross-runtime **agent configuration superset** (`agent.json`).
    pub const agent = @import("agent");
    /// Named tool groups with transitive includes (`toolsets.json`).
    pub const toolset = @import("toolset");
    /// Marketplace/library index schema.
    pub const library = @import("library");
    /// `.claude-plugin/plugin.json` manifest schema.
    pub const plugin = @import("plugin");
    pub const source = @import("schema/source.zig");
    pub const marketplace = @import("schema/marketplace.zig");
    /// `.mcp.json` MCP-server config.
    pub const mcp = @import("schema/mcp.zig");
    /// `.lsp.json` language-server config.
    pub const lsp = @import("schema/lsp.zig");
    /// Lifecycle hooks config.
    pub const hooks = @import("schema/hooks.zig");
};

/// Resolution, materialization, compatibility, and runtime emitters.
pub const core = struct {
    pub const manifest = @import("core/manifest.zig");
    pub const lockfile = @import("core/lockfile.zig");
    pub const sandbox = @import("core/sandbox.zig");
    pub const resolver = @import("core/resolver.zig");
    pub const config = @import("core/config.zig");
    /// Plugin compatibility (semver) gate.
    pub const compat = @import("compat");
    /// Cross-file agent validation (capabilities/toolset/prompt).
    pub const agent_resolver = @import("agent_resolver");
    /// Toolset flattening (transitive includes + cycle detection).
    pub const toolset_resolver = @import("toolset_resolver");
    /// 3-layer (library/project/agent) capability materialization.
    pub const materialize = @import("materialize");
    /// **Emitters**: `Agent` → native config for claude/openclaw/hermes/pi.
    pub const emit = @import("emit");
};

/// Plugin source fetchers (git, GitHub, http, local).
pub const fetch = struct {
    pub const fetcher = @import("fetch/fetcher.zig");
    pub const git = @import("fetch/git.zig");
    pub const github = @import("fetch/github.zig");
    pub const http = @import("fetch/http.zig");
    pub const local = @import("fetch/local.zig");
};

/// Content-addressed blob store (`~/.mc/cache`).
pub const cache = struct {
    pub const store = @import("cache/store.zig");
    pub const index = @import("cache/index.zig");
};

test {
    // Force every namespace's `@import` to resolve so the public surface is
    // verified to actually wire up for consumers (function bodies are already
    // exercised by the executable build and the per-module test suites).
    const testing = @import("std").testing;
    testing.refAllDecls(io);
    testing.refAllDecls(schema);
    testing.refAllDecls(core);
    testing.refAllDecls(fetch);
    testing.refAllDecls(cache);
}
