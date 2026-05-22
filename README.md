# mc

**One source of truth for configuring managed coding agents.**

`mc` is a small, fast (zero-copy) tool — and Zig library — for two jobs:

1. **Package management** for coding-assistant *capabilities*: skills, slash
   commands, extensions, toolsets, MCP/LSP servers and hooks, installed from
   marketplaces into a project sandbox (`.mc/`).
2. **Cross-runtime agent configuration.** Describe an agent **once** in
   `agent.json` (a superset schema) and emit native config for any managed-agent
   runtime — [Claude Managed Agents](https://platform.claude.com/docs/en/managed-agents/overview),
   [OpenClaw](https://github.com/openclaw/openclaw),
   [Hermes](https://github.com/nousresearch/hermes-agent), or
   [Pi](https://github.com/earendil-works/pi).

The headline idea: a **canonical superset** of the fields every runtime shares,
a **per-runtime passthrough** (`targets.<runtime>`, deep-merged) for everything
else, and **no silent drops** — if a target can't represent a field you set, the
tool tells you. See [`docs/agent-config-superset.md`](docs/agent-config-superset.md).

## Documentation

- **[Using `mc` as a package manager](docs/package-manager.md)** — marketplaces, plugins, the sandbox, lockfile, `generate`, and compatibility gating.
- **[Agent configuration superset](docs/agent-config-superset.md)** — the one-`agent.json` model and the cross-runtime emitters.

---

## Requirements

- **Zig 0.16** (`zig version` → `0.16.0-dev` or newer). libc is linked.

## Build

```sh
zig build              # build the `mc` CLI → zig-out/bin/mc
zig build run -- ...   # build & run the CLI
zig build test         # run the test suite
zig build test-config  # run just the agent-config + emitter tests (no filesystem)
zig build sandbox      # emit + validate configs for every runtime (well-formed, shaped, no secrets)
zig build example      # run the library-consumer example
```

## CLI quickstart

```sh
mc init --name my-project          # create a .mc/ sandbox
mc add <plugin> -m <marketplace>   # install a capability plugin
mc agent new reviewer              # scaffold agents/reviewer/{agent.json,prompt.md}
mc agent emit reviewer --target claude     # → Claude Code subagent (.claude/agents/*.md)
mc agent emit reviewer --target managed    # → Anthropic Managed Agents create body
mc agent emit reviewer --target openclaw   # → OpenClaw agents.list[] entry
mc agent emit reviewer --target hermes     # → Hermes config.yaml
mc agent emit reviewer --target google     # → Google AX ax.yaml
mc agent emit reviewer --target pi --out d # → materialize d/.pi/agent/{models,settings}.json
mc run reviewer --dry-run          # preview the pi command for this agent
mc validate                        # validate every config file + cross-references
```

`mc agent emit` prints native config to **stdout** (clean, pipeable) and any
"this field isn't representable on that runtime" **warnings to stderr**. The
full package-manager workflow (marketplaces, plugins, lockfile, `generate`) is
documented in **[docs/package-manager.md](docs/package-manager.md)**.

## The agent configuration superset

One `agent.json` (existing required keys plus optional superset keys):

```jsonc
{
  "name": "reviewer",
  "description": "Reviews PRs",
  "model": "claude-opus-4-7",
  "provider": "anthropic",
  "thinking": "high",
  "prompt": "./prompt.md",
  "capabilities": { "skills": ["code-review"], "commands": [], "extensions": [], "toolset": "read-only" },
  "env": { "required": ["ANTHROPIC_API_KEY"], "optional": [] },

  "runtime": "claude",                 // default emitter: claude | openclaw | hermes | pi
  "system": "You are a careful reviewer.",
  "speed": "fast",
  "permissions": { "default": "always_allow" },
  "mcp_servers": { "linear": { "url": "https://mcp.linear.app/sse" } },
  "multiagent": { "delegates": ["tester"] },

  "targets": {                         // per-runtime raw overrides, deep-merged
    "claude": { "metadata": { "team": "infra" } }
  }
}
```

`mc agent emit reviewer` then yields a valid Claude `agents.create` body (model
`{id, speed}`, MCP URL connectors + `mcp_toolset` refs, a `permission_policy`,
skills and a `multiagent` roster) — with `targets.claude` deep-merged on top.
The full field-by-field mapping across all four runtimes is in
[`docs/agent-config-superset.md`](docs/agent-config-superset.md).

---

## Use as a library

Add `mc` as a dependency:

```sh
zig fetch --save https://github.com/qu0b/mc/archive/refs/tags/v0.2.0.tar.gz
```

That records it in your `build.zig.zon`:

```zig
.dependencies = .{
    .mc = .{
        .url = "https://github.com/qu0b/mc/archive/refs/tags/v0.2.0.tar.gz",
        .hash = "mc-0.2.0-5z6NHy5PCACXGMBmR_xTFrChIzHXxi0z6x5xWZrbOlCg",
    },
},
```

Wire the module into your `build.zig`:

```zig
const mc = b.dependency("mc", .{
    .target = target,
    .optimize = optimize,
}).module("mc");

exe.root_module.addImport("mc", mc);
exe.root_module.link_libc = true; // mc's IO layer links libc
```

Then `@import("mc")`:

```zig
const std = @import("std");
const mc = @import("mc");

var diags = mc.io.diagnostic.Diagnostics.init(allocator);
defer diags.deinit();

const agent = (try mc.schema.agent.parseAgent(allocator, "agent.json", src, &diags)).?;

// Emit native config for any runtime:
const claude_json = try mc.core.emit.emitClaude(allocator, agent, prompt_text);
const hermes_yaml = try mc.core.emit.emitHermes(allocator, agent, prompt_text);

// Find anything a target can't represent:
for (try mc.core.emit.warnings(allocator, agent, .claude)) |w|
    std.log.warn("{s}", .{w});
```

A complete, runnable version is in [`examples/emit_agent.zig`](examples/emit_agent.zig)
(`zig build example`).

### Public API

`@import("mc")` exposes four namespaces (see [`src/root.zig`](src/root.zig) for
doc comments on each member):

| Namespace | Contents |
| --- | --- |
| `mc.io`     | `diagnostic`, `json_strict` (schema validator), `semver`, `json`, `mmap`, `compat` (IO shim) |
| `mc.schema` | `agent` (the superset), `toolset`, `plugin`, `library`, `mcp`, `lsp`, `hooks`, `source`, `marketplace` |
| `mc.core`   | `emit` (runtime emitters), `agent_resolver`, `toolset_resolver`, `materialize`, `compat`, `config`, `manifest`, `lockfile`, `resolver`, `sandbox` |
| `mc.fetch`  | `git`, `github`, `http`, `local`, `fetcher` |
| `mc.cache`  | `store`, `index` (content-addressed blob store) |

Everything is allocator-explicit; the schema/emitter layer (`mc.schema`,
`mc.core.emit`) is pure (no filesystem) and can be used standalone.

---

## Repository layout

```
src/
  io/        primitives: diagnostics, strict-JSON validator, semver, json, mmap, IO compat shim
  schema/    strict schemas: agent (superset), toolset, plugin, library, mcp, lsp, hooks, …
  core/      emit (runtime emitters), resolvers, materialize, compat, config, lockfile, …
  fetch/     plugin source fetchers (git/github/http/local)
  cache/     content-addressed store
  cli/       the `mc` command surface
  root.zig   library entry point (the public API)
  main.zig   CLI entry point
tests/       per-module test suites
examples/    runnable library-consumer example
docs/        design docs (agent-config superset)
```

## Testing

```sh
zig build test         # full suite
zig build test-config  # agent-config superset + emitters only (pure, fast)
```

Tests live under `tests/` (one suite per module) and inline in `src/`. The
emitter and schema behaviour — deep-merge, MCP modeling, permission mapping,
drop-warnings, plus a golden Claude shape — is covered in
`tests/core/emit_test.zig` and `tests/schema/agent_test.zig`.
