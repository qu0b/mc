# mc as a one-source-of-truth agent configuration tool

`mc` already manages *capabilities* (skills/commands/extensions/toolsets/MCP/LSP/hooks)
and defines *agents* in `agents/<name>/agent.json`. Today an agent is described with a
minimal, **pi-specific** shape and `mc run` hard-codes a `pi …` command line.

The goal: make `agent.json` a **superset configuration** that can target *any* managed-agent
runtime — Anthropic's Managed Agents API, [Hermes](https://github.com/nousresearch/hermes-agent),
[OpenClaw](https://github.com/openclaw/openclaw), and [Pi](https://github.com/earendil-works/pi) —
from one canonical definition, plus an escape hatch for runtime-specific knobs.

## Three ideas

1. **Canonical superset** — the fields that recur across every runtime are first-class,
   strictly-validated keys (model, system prompt, tools, MCP servers, skills, env, sandbox,
   permissions, memory, sub-agents, metadata).
2. **Per-target passthrough with deep merge** — anything a specific runtime supports that
   the superset does not is expressed under `targets.<runtime>` as raw JSON and
   **deep-merged** (RFC 7386 JSON Merge Patch) over the canonical output: nested objects
   merge recursively, arrays/scalars replace, and a JSON `null` deletes a key. This keeps
   the common case clean while staying 100% expressive — you can override one nested field
   without restating the whole block.
3. **No silent drops** — when a target's emitter cannot represent a field the agent sets
   (e.g. `sandbox` for the Claude *agent* resource), `mc agent emit` prints a `warning`
   to stderr saying so. The schema never quietly ignores configuration.

The `runtime` field selects the default emitter; `mc agent emit` (and `mc run` for pi)
turns the canonical config (+ deep-merged target overrides) into the runtime's native format.

### Layering: `capabilities` vs `tools` vs `mcp`

These are complementary layers, not competitors:
- **`capabilities.{toolset,skills,commands,extensions}`** — what `mc` *materializes* and
  installs (used by the pi runtime via the resolved toolset). The mc package layer.
- **`tools.{allow,deny,builtin}`** — cross-runtime tool *policy* applied by managed
  runtimes (e.g. OpenClaw `tools.allow/deny`).
- **`mcp` / `mcp_servers`** — MCP server *references* and *definitions* (command/url).

## Field mapping across runtimes

| Canonical (`agent.json`)        | Claude Managed Agents          | Hermes (`config.yaml`)            | OpenClaw (`openclaw.json`)            | Pi (`settings.json` / CLI)      |
|---------------------------------|--------------------------------|-----------------------------------|---------------------------------------|---------------------------------|
| `name`                          | `name`                         | profile name                      | `agents.list[].id` / `name`           | —                               |
| `description`                   | `description`                  | —                                 | `description`                         | —                               |
| `model`                         | `model` / `model.id`           | `model.default`                   | `agents.*.model`                      | `defaultModel` / `--model`      |
| `provider`                      | (implicit Anthropic)           | `model.provider`                  | `models.providers.*`                  | `defaultProvider` / `--provider`|
| `thinking`                      | (model speed)                  | `agent.reasoning_effort`          | `thinkingDefault`                     | `defaultThinkingLevel`          |
| `speed`                         | `model.speed` (fast)           | `service_tier`                    | `fastModeDefault`                     | —                               |
| `prompt` (file) / `system`      | `system`                       | `soul.md`                         | `systemPromptOverride`                | `--system-prompt`               |
| `max_tokens`,`temperature`,`context_window` | (request params)  | `model.max_tokens`/`context_length` | provider/model `params`             | `thinkingBudgets`/params        |
| `api_key_env`, `base_url`       | env / vault                    | `model.api_key`/`base_url`        | `models.providers.*.apiKey/baseUrl`   | `auth.json` / env               |
| `capabilities.toolset` + `tools.allow/deny` | `tools[]` (typed)  | `platform_toolsets` / toolsets    | `tools.allow/deny/profile`            | `--tools` CSV                   |
| `capabilities.skills`           | `skills[]`                     | `skills.external_dirs`            | `agents.*.skills`                     | `--skill` / `skills[]`          |
| `capabilities.extensions`       | (tools)                        | `plugins`                         | `plugins`                             | `--extension` / `extensions[]`  |
| `mcp[]`                         | `mcp_servers[]` + `mcp_toolset`| `mcp_servers{}`                   | `mcp.servers{}`                       | (via extensions)                |
| `env.required/optional`,`env.vars` | environment / vaults        | `.env`                            | `env.vars`                            | process env                     |
| `sandbox.*`                     | environment (container)        | `terminal.backend`/`docker_*`     | `agents.*.sandbox`                    | (local)                         |
| `permissions.default/rules`     | tool `permission_policy`       | `approvals`                       | `tools` policy / `approvals`          | —                               |
| `memory.enabled/backend`        | memory store                   | `memory`                          | `memory`                              | —                               |
| `multiagent.delegates[]`        | `multiagent.agents`            | `delegation`                      | `subagents.allowAgents`               | —                               |
| `metadata`                      | `metadata`                     | —                                 | `meta`                                | —                               |
| `targets.<rt>` (raw)            | passthrough                    | passthrough                       | passthrough                           | passthrough                     |

## Canonical `agent.json` (superset)

Existing required keys are unchanged (back-compatible). All superset keys are **optional**:

```jsonc
{
  "name": "reviewer",
  "description": "Reviews PRs",
  "model": "claude-opus-4-7",
  "provider": "anthropic",
  "thinking": "medium",
  "prompt": "./prompt.md",
  "capabilities": { "skills": [], "commands": [], "extensions": [], "toolset": "read-only" },
  "env": { "required": ["ANTHROPIC_API_KEY"], "optional": [] },

  // ---- superset (all optional) ----
  "runtime": "claude",                 // pi | claude | hermes | openclaw  (default emitter)
  "system": "You are a careful reviewer.",   // inline system prompt (overrides prompt file)
  "speed": "fast",                     // standard | fast
  "max_tokens": 8192,
  "temperature": 0.2,
  "context_window": 200000,
  "api_key_env": "ANTHROPIC_API_KEY",
  "base_url": "https://api.anthropic.com",
  "mcp": ["linear", "github"],         // allowlist; empty = attach all of mcp_servers
  "mcp_servers": {                     // server *definitions* (the source of truth)
    "linear": { "url": "https://mcp.linear.app/sse" },
    "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] }
  },
  "tools": { "allow": ["read", "grep"], "deny": ["bash"], "builtin": true },
  "permissions": { "default": "ask", "rules": { "read": "always_allow" } },
  "sandbox": { "backend": "anthropic", "image": "node:22", "cpu": 2, "memory": 4096,
               "network": "restricted", "workdir": "/workspace" },
  "memory": { "enabled": true, "backend": "store" },
  "multiagent": { "delegates": ["researcher", "tester"] },
  "metadata": { "team": "infra" },

  // ---- per-runtime raw passthrough, deep-merged (escape hatch) ----
  "targets": {
    "claude":   { "metadata": { "cost_center": "eng" } },   // merged into metadata, not replacing it
    "hermes":   { "agent": { "max_turns": 120 } },           // merged into the agent block
    "openclaw": { "gateway": { "port": 8080 } }              // a key the superset doesn't model
  }
}
```

## Emitters (`src/core/emit.zig`)

Pure functions `Agent (+ prompt text) -> native config bytes`. All four runtimes
the goal named are implemented:

- **claude** — Managed Agents `agents.create` body (JSON). Maps `mcp_servers` →
  URL connectors + `mcp_toolset` refs, and `permissions.default` →
  `tools[].default_config.permission_policy`. ✅
- **openclaw** — `openclaw.json` `agents.list[]` entry (JSON). ✅
- **hermes** — `config.yaml` fragment (YAML, via a small JSON-value→YAML writer);
  maps model/`reasoning_effort`/`mcp_servers`/`terminal`/`memory`. ✅
- **pi** — `pi` argv (`emitPiArgv`; the locked-down loadout `mc run` builds). ✅

Every emitter builds a `std.json.Value` tree and **deep-merges** the matching
`targets.<runtime>` object over it (RFC 7386), so even nested runtime-specific
overrides work without schema changes. `warnings(agent, target)` reports any set
field the target can't represent.

## CLI

```
mc agent emit <name> [--target claude|openclaw|pi]
```

Loads `agents/<name>/agent.json`, resolves the target (defaults to the agent's
`runtime`), and prints the native config. `--target pi` points to
`mc run <name> --dry-run`, which prints the full materialized pi command.

Validate the config layer in isolation (no filesystem) with:

```
zig build test-config
```
