# Using `mc` as a package manager

`mc` installs **capabilities** for coding assistants — skills, slash commands,
extensions, toolsets, and MCP / LSP servers and hooks — from **marketplaces**
into a per-project **sandbox**, with a content-addressed cache and a lockfile
for reproducible installs.

This guide covers the package-manager workflow. For turning installed
capabilities into a runnable agent and emitting native config for managed-agent
runtimes, see [`agent-config-superset.md`](agent-config-superset.md).

---

## Mental model

| Thing | What it is | Where it lives |
| --- | --- | --- |
| **Sandbox** | A project initialized for `mc` | `<project>/.mc/` |
| **Manifest** | Project metadata | `<project>/.mc/mc.json` |
| **Lockfile** | Exact installed plugins (pinned by content hash) | `<project>/.mc/mc.lock` |
| **Plugins** | Installed capabilities | `<project>/.mc/plugins/<name>/` |
| **Marketplace** | A git repo indexing installable plugins | `~/.mc/marketplaces/<name>/` (global) |
| **Cache** | Content-addressed blob store (dedup across projects) | `~/.mc/cache/sha256-<hash>/` |

Marketplaces are **global** (shared across all your projects); plugins are
installed **per-project** into the sandbox. The cache means installing the same
plugin in two projects downloads it once.

### On-disk layout

```
~/.mc/                              # global
├── config.json                     # global config (optional)
├── marketplaces/<name>/            # cloned marketplace repos
│   └── .claude-plugin/marketplace.json
└── cache/sha256-<hash>/            # content-addressed plugin blobs

<project>/.mc/                      # per-project sandbox
├── mc.json                         # manifest
├── mc.lock                         # lockfile (reproducible installs)
└── plugins/<name>/                 # installed plugins
```

---

## Quickstart

```sh
# 1. Initialize a project sandbox.
mc init --name my-project

# 2. Register a marketplace (a git repo with .claude-plugin/marketplace.json).
mc marketplace add official --github anthropics/claude-plugins-official

# 3. Discover plugins.
mc search review
mc info quality-review

# 4. Install a plugin into the project.
mc add quality-review            # or: mc add quality-review@official

# 5. (optional) Generate merged tool configs from installed plugins.
mc generate all                  # writes .mcp.json / .lsp.json

# 6. Validate everything.
mc validate
```

Installing records the plugin (pinned by content hash + source) in
`.mc/mc.lock`. Commit `.mc/mc.json` and `.mc/mc.lock`; a teammate then runs
`mc install` to reproduce the exact set.

---

## Commands

Aliases: `rm`=remove, `ls`=list, `s`=search, `mp`=marketplace, `gen`=generate,
`i`=install, `-V`=`--version`.

### Project

```sh
mc init [--name <name>]
```
Creates `.mc/mc.json` and `.mc/plugins/`, and ensures `~/.mc/{cache,marketplaces}`.
Idempotent — warns if a sandbox already exists. `--name` defaults to the
directory name.

### Marketplaces (global)

```sh
mc marketplace add <name> --github <owner/repo>   # clone from GitHub
mc marketplace add <name> --url <git-url>         # clone from any git URL
mc marketplace list                               # list registered marketplaces + plugin counts
mc marketplace update [<name>]                    # git pull one (or all) marketplaces
mc marketplace remove <name>                      # delete a marketplace clone
```
`add` git-clones into `~/.mc/marketplaces/<name>` and requires a
`.claude-plugin/marketplace.json` at the repo root (the clone is discarded if
it's missing).

### Plugins (per-project)

```sh
mc add <pkg>[@<marketplace>] [-m <marketplace>] [-v <version>] [-I|--ignore-compat]
mc add --url <git-url> [-I]        # install directly from a git repo
mc add --path <local-path> [-I]    # install directly from a local directory
mc remove <pkg>                    # delete <project>/.mc/plugins/<pkg>
mc list [--json]                   # list installed plugins
mc search <query> [-m <marketplace>]   # substring search over name/description
mc info <pkg>                      # show plugin details
mc install [-I|--ignore-compat]    # re-install everything pinned in mc.lock
mc update [<pkg>]                  # re-install from the lockfile
```

`mc add <pkg>` resolves the plugin across all registered marketplaces (use
`<pkg>@<marketplace>` or `-m` to disambiguate), fetches its source, runs the
[compatibility gate](#compatibility-gating), links it into `.mc/plugins/<pkg>`,
and records it in `.mc/mc.lock`. Direct `--url` / `--path` installs are recorded
under the `direct` marketplace.

`mc install` re-links every locked package from the content-addressed cache,
after a **batch** compatibility pre-flight (it refuses to install *any* plugin
if *any* fails, unless `--ignore-compat` — partial installs would leave the
sandbox ambiguous).

### Config generation

```sh
mc generate mcp     # merge installed plugins' .mcp.json   → ./.mcp.json
mc generate lsp     # merge installed plugins' .lsp.json   → ./.lsp.json
mc generate hooks   # merge installed plugins' hooks
mc generate all     # all of the above
```
`${CLAUDE_PLUGIN_ROOT}` in plugin MCP commands/args is expanded to the plugin's
install path during generation.

### Validation

```sh
mc validate         # validate every config file + cross-references; exit 1 on errors
```
Checks installed `plugin.json` manifests (schema + compat), `toolsets.json`
(schema + include-graph cycles/unknowns), `marketplace.json`, and each
`agents/<name>/agent.json` (schema + capability/toolset/prompt cross-refs). All
diagnostics are aggregated and printed once.

---

## File formats

### Manifest — `.mc/mc.json`

```json
{
  "name": "my-project",
  "plugins": {},
  "marketplaces": {}
}
```

### Lockfile — `.mc/mc.lock`

Pins each installed plugin by content hash and source for reproducibility:

```json
{
  "version": 1,
  "packages": {
    "quality-review@official": {
      "version": "1.2.0",
      "content_hash": "<sha256>",
      "source_type": "github",
      "git_sha": "<commit>"
    }
  }
}
```

### Marketplace index — `.claude-plugin/marketplace.json`

A marketplace repo lists its plugins. Each plugin's `source` is polymorphic
(see below):

```json
{
  "name": "official",
  "owner": { "name": "Anthropic", "email": "plugins@anthropic.com" },
  "plugins": [
    {
      "name": "quality-review",
      "source": { "source": "github", "repo": "anthropics/quality-review", "ref": "v1.2.0" },
      "description": "Adds a /quality-review skill",
      "version": "1.2.0",
      "category": "review",
      "keywords": ["review", "quality"]
    },
    { "name": "local-tool", "source": "./plugins/local-tool" }
  ]
}
```

#### Plugin source types

The `source` field is either a string (a local path relative to the marketplace
repo) or an object with a `source` discriminator:

| `source` | Fields | Meaning |
| --- | --- | --- |
| *(string)* | `"./path"` | Local path inside the marketplace repo |
| `github` | `repo`, `ref?`, `sha?` | GitHub repository |
| `url` | `url`, `ref?`, `sha?`, `path?` | Any git URL |
| `git-subdir` | `url`, `path`, `ref?`, `sha?` | A subdirectory of a git repo (sparse) |
| `npm` | `package`, `version?`, `registry?` | npm package |

### Plugin manifest — `plugin.json`

An installed plugin carries a `.claude-plugin/plugin.json` (or top-level
`plugin.json`) describing what it provides (`commands`, `agents`, `skills`,
`hooks`, `mcpServers`, `lspServers`, …) and an optional `compat` block.

---

## Compatibility gating

A plugin may declare semver ranges it requires of the host:

```json
{
  "name": "quality-review",
  "compat": {
    "pluginApi":    "^1.0.0",   // mc's plugin-contract version
    "minMcVersion": ">=0.1.0",  // host mc version
    "minPiVersion": ">=0.5.0"   // host pi version (checked only if pi is installed)
  }
}
```

`mc add` and `mc install` check these against live host facts and **refuse** the
operation on any violation, emitting a diagnostic per unsatisfied range. Pass
`--ignore-compat` (`-I`) to downgrade the errors to warnings and proceed anyway.

---

## From plugins to agents

Installed plugins are the *capability* layer. An agent (`agents/<name>/agent.json`)
references them by name — `capabilities.skills`, `capabilities.extensions`,
`capabilities.toolset` — and `mc run` materializes the referenced capabilities
into the agent's runtime directory before launching. The same `agent.json` can
be emitted to managed-agent runtimes with `mc agent emit`. See
[`agent-config-superset.md`](agent-config-superset.md).
