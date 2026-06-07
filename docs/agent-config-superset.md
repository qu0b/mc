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

Pure functions `Agent (+ prompt text) -> native config bytes`. **Six** runtimes
are implemented:

- **claude** — Anthropic **Claude Code**: a `.claude/agents/<name>.md` subagent
  (frontmatter `name/description/model`-alias/`tools` + system-prompt body); with
  `--out`, also `.claude/settings.json` and `.mcp.json`. ✅
- **managed** — Anthropic **Managed Agents** `agents.create` body (JSON). Maps
  `mcp_servers` → URL connectors + `mcp_toolset` refs, and `permissions.default`
  → `tools[].default_config.permission_policy`. ✅
- **openclaw** — `openclaw.json` `agents.list[]` entry (JSON). ✅
- **hermes** — `config.yaml` (YAML); maps model/`reasoning_effort`/`mcp_servers`/
  `terminal`/`memory`. ✅
- **pi** — a `~/.pi/agent` config that **pins the exact provider + model id**:
  `models.json` (`emitPiModels`) and `settings.json` (`emitPiSettings`), avoiding
  pi's fuzzy `--model` resolution. `emitPiArgv` is the **single** argv builder
  (`mc run` routes through it, no divergence) and emits the verified pi 0.73
  invocation:
  `pi -p --system-prompt <TEXT> --provider local-llm --model <M> --thinking <lvl>
  --tools <csv> --mode json --no-session --no-extensions [--no-skills | --skill
  <dir> …] @<taskfile>`.
  `-p` / `--print` is a **boolean** (non-interactive); the system prompt is a
  single literal `--system-prompt` argv element (array exec, no shell → no
  base64/quoting); `--no-skills` is emitted **only** when zero skills are attached
  (else one `--skill <dir>` per skill); the task is the trailing positional
  `@<taskfile>` (pi expands `@file` only in the positional). MCP is a Phase-1
  no-op (warning only, never wired). ✅
- **google** — Google **AX** (`Agent eXecutor`) `ax.yaml`: a gemini `planner`
  (model/`system_prompt`/sampling) + a `registry.remote_agents[]` entry. ✅

Every JSON emitter builds a `std.json.Value` tree and **deep-merges** the matching
`targets.<runtime>` object over it (RFC 7386), so even nested runtime-specific
overrides work without schema changes. `warnings(agent, target)` reports any set
field the target can't represent.

### Providers are open

`provider` is **not** a closed enum — it accepts any lowercase slug (e.g. a
self-hosted gateway named `local-llm`) and only *warns* when the name isn't a
built-in. The `api` field (wire protocol, e.g. `anthropic-messages`) and
`reasoning` flag let an emitter pin a complete provider definition.

## CLI

```
mc agent emit <name> [--target claude|openclaw|hermes|pi] [--out <dir>]
mc agent emit --file <agent.json> --target pi --out <dir>   # standalone, no .mc sandbox
mc run <name> --print-argv -- @<taskfile>                   # machine-readable pi argv
mc run --file <agent.json> --print-argv -- @<taskfile>      # standalone run
```

Loads `agents/<name>/agent.json`, resolves the target (defaults to the agent's
`runtime`), and **prints** the native config to stdout (warnings → stderr).

### Standalone / non-interactive surfaces

`--file <agent.json>` reads a **lone** `agent.json` with no `.mc` sandbox (the
prompt resolves relative to the file's dir; the toolset resolves from a sibling
`toolsets.json`, or — when absent — `capabilities.toolset` is treated as a single
pre-resolved tool id). Skills/extensions are **pre-staged** dirs handed straight
to `--skill` (absolute verbatim, relative resolved against the file's dir) — mc
never invokes a package manager in this mode.

`mc run --print-argv` prints the exact pi argv, **one element per line, raw**
(NOT shell-quoted, NOT masked), so an external runner can exec the array
verbatim — faithfulness (including the full `--system-prompt` text) wins over
copy-paste safety. `--dry-run` is the human surface: it shell-quotes and masks
the `--system-prompt` value as `<PROMPT>`. The task is supplied as the trailing
positional after `--` (e.g. `-- @/workspace/.pi-task.md`).

With **`--out <dir>`** it instead *materializes every file the target needs*:

- **pi** → `<dir>/.pi/agent/models.json` + `settings.json`, so launching is just
  `HOME=<dir> pi -p "…"` (no `--provider`/`--model` flags, no fuzzy match). If the
  env var named by `api_key_env` is set, its value is injected into `models.json`
  (written mode `0600`); otherwise the key is left out with a note.
- **claude/openclaw/hermes** → the single config file (`agent.json` /
  `openclaw-agent.json` / `config.yaml`).

Validate the config layer in isolation (no filesystem) with:

```
zig build test-config
```

## Sandbox validation

`zig build sandbox` (→ `tests/sandbox/validate.sh`) is an end-to-end harness: it
emits every runtime's config from representative `tests/sandbox/fixtures/*.json`
and confirms each output is **well-formed** (real JSON/YAML parse), matches that
runtime's **expected shape** (key/value assertions), and **leaks no secret**.
It also exercises `--out` materialization (e.g. pi's `.pi/agent/` with the key
omitted when `api_key_env` is unset) and verifies `targets.<runtime>` passthrough
reaches every runtime.

**Real-runtime confirmation:** set `AX_REPO=<google/ax checkout>` (with `go`
installed) and the harness validates the emitted `ax.yaml` against AX's *own*
`config.LoadFromFile` + `Validate` — confirming mc emits a config AX genuinely
accepts (this is why the AX emit includes the `server`/`eventlog` blocks AX
requires). Add a fixture to cover a new scenario; the same opt-in pattern can
plug openclaw's zod / pi's loader for those runtimes.
