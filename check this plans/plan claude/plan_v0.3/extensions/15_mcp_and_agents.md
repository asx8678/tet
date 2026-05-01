# 15 — Extensions: MCP, Multi-Agent, Custom Commands

> **Scope: v1.x, not v1.** Moved here in v0.3 from the v0.2 upgrades
> bucket because tagging these as v1 acceptance was scope creep.
> See `upgrades/17_phasing_and_scope.md`. Specific corrections in v0.3:
> MCP `readOnlyHint` is no longer trusted (operator allowlist required);
> custom-command templating uses EEx instead of an invented `{{var}}`
> dialect; AGENT.md applies to all modes (chat included).

The original plan ignored MCP, assumed a single agent, and had no
slash-command surface. Code Puppy ships all three. They fit Tet
naturally if added on top of the v1 foundation.

## MCP client

Model Context Protocol is the de facto integration surface for LLM
tools. Treated as another tool source behind `Tet.Tool`.

### Boundary

MCP is a **driving adapter**, not a driver of business logic. An MCP
server announces tools; Tet wraps each as a `Tet.Tool` implementation
whose `run/2` proxies through the MCP transport. Mode policy, path
policy, trust state, approvals, redaction, and the workflow journal
all still apply.

### Transport

- **stdio**: spawn an MCP server as a subprocess.
  `Tet.MCP.Transport.Stdio`, supervised under
  `Tet.MCP.ClientSupervisor`. Subprocess sandboxing is the OS's job;
  Tet does not sandbox.
- **HTTP/SSE**: connect to a remote MCP server.
  `Tet.MCP.Transport.HTTP` using `Finch`. Auth tokens come from
  `Tet.Secrets`, never from `config.toml`.

### Tool registration

Each connection runs a discovery handshake (`tools/list`) and registers
each tool under a namespaced name:

```text
mcp:<server_name>:<tool_name>
```

For example, an MCP server named `puppeteer` exposing `screenshot`
becomes `mcp:puppeteer:screenshot`. Naming prevents collisions across
servers and from native tools.

### Read-only classification — operator allowlist, not server self-report

MCP servers can declare `annotations.readOnlyHint = true` on their
tools. **Tet does not trust this.** A malicious or buggy MCP server
that lies about read-only status would bypass mode/approval policy.

Instead:

- All MCP tools default to `:write` classification.
- An operator declares specific tools as `:read` in `config.toml` after
  manual review:

```toml
[mcp.readonly_tools]
"puppeteer:screenshot" = true
"github:list_issues" = true
```

- Server self-report is shown for context (`tet mcp tools <name>`
  prints the `readOnlyHint` value) but never automatically applied.

This is conservative but the only safe default for third-party
integrations.

### Configuration

```toml
[mcp.servers.puppeteer]
transport = "stdio"
command = "npx"
args = ["@modelcontextprotocol/server-puppeteer"]
auto_start = true

[mcp.servers.github]
transport = "http"
url = "https://api.github.com/mcp"
auth_token_secret = "GITHUB_TOKEN"   # resolved via Tet.Secrets
auto_start = false
```

### CLI

```text
tet mcp list                       registered servers and status
tet mcp start <server_name>        starts/connects
tet mcp stop  <server_name>        disconnects
tet mcp status <server_name>       handshake info, tool count
tet mcp tools <server_name>        tools advertised + readOnlyHint values
```

Slash commands inside `tet chat` mirror these.

### MCP and modes

- `:chat` — MCP tools blocked.
- `:explore` — only operator-allowlisted `:read` MCP tools allowed.
- `:execute` — write-classified MCP tools route through approval.

Tool calls are recorded as workflow steps and survive restart. If an
MCP server dies mid-call, the workflow recovery mechanism handles it
the same way it handles a native tool crash.

### Acceptance

- [ ] `Tet.MCP.Transport.Stdio` and `Tet.MCP.Transport.HTTP` pass
      conformance tests against MCP reference servers.
- [ ] Discovery handshake registers tools under namespaced names.
- [ ] All MCP tools default to `:write`; operator allowlist promotes
      specific tools to `:read`.
- [ ] `readOnlyHint` is shown in `tet mcp tools` but never used to
      change classification automatically.
- [ ] MCP tool calls are recorded as workflow steps.
- [ ] MCP credentials live in `Tet.Secrets`, not `config.toml`.

## Multi-agent

The original plan implies a single agent. Code Puppy supports many,
selectable per-session, each with its own system prompt and tool
subset. Useful product feature with low implementation cost.

### Concept

An **agent profile** is a named bundle of:

- system prompt (string or list-of-strings);
- tool allowlist (subset of registered tools);
- optional default mode (`:chat`, `:explore`, `:execute`);
- optional default model;
- optional `tools_config` (timeouts, retries per tool).

Profiles live as JSON in `~/.config/tet/agents/<name>.json` (user) or
`<workspace>/.tet/agents/<name>.json` (workspace, wins). Built-in
profiles ship in `priv/agents/` of `tet_runtime`.

### Schema

```json
{
  "name": "code-tet",
  "display_name": "Tet 🟦",
  "description": "Default coding assistant",
  "system_prompt": [
    "You are a careful coding assistant.",
    "Propose patches as unified diffs."
  ],
  "tools": ["list_dir", "read_file", "search_text", "git_status",
            "git_diff", "propose_patch", "run_command"],
  "default_mode": "execute",
  "default_model": null,
  "tools_config": {
    "read_file": { "timeout_ms": 5000 },
    "run_command": { "timeout_ms": 90000 }
  }
}
```

Validation lives in `tet_core` (`Tet.Agent.Profile.validate/1`); the
runtime loads and caches profiles in `Tet.Agent.Registry`.

### Selection

```text
tet session new . --agent code-tet
tet session new . --agent reviewer --mode explore
```

Inside `tet chat`:

```text
/agent              list available
/agent <name>       switch active agent for THIS session
```

### Built-in profiles

- `code-tet` — default, all tools, `:execute` default.
- `explore-only` — read tools, `:explore` default.
- `reviewer` — read tools + `git_diff`, `:explore`, prompt steered
  toward review feedback rather than edits.

### Boundary

Agent profiles are configuration data, not code. They cannot extend
the tool set — only restrict it. Adding a new tool still requires a
`Tet.Tool` implementation.

### Acceptance

- [ ] `Tet.Agent.Profile` schema and validator in core.
- [ ] `Tet.Agent.Registry` loads built-in + user + workspace profiles
      with workspace winning.
- [ ] `tet session new --agent <name>` creates a session bound to the
      profile.
- [ ] `/agent <name>` switches mid-session and emits an event.
- [ ] An agent's tool allowlist is enforced:
      `:tool_not_in_agent_profile`.

## Custom slash commands

Code Puppy reads markdown files from `.claude/commands/`,
`.github/prompts/`, or `.agents/commands/` and turns each into a slash
command whose body becomes the prompt. We adopt the convention so
existing prompt libraries work in Tet without porting.

### Discovery

In priority order:

```text
<workspace>/.tet/commands/<name>.md
<workspace>/.claude/commands/<name>.md
<workspace>/.github/prompts/<name>.md
~/.config/tet/commands/<name>.md
```

The filename (without `.md`) becomes the command. Front-matter
declares parameters:

```markdown
---
description: Review this code for security issues.
arguments:
  - name: focus
    description: What to focus on
    required: false
    default: general issues
---

# Code Review

Please review the code with attention to <%= @focus %>.
```

### Templating: EEx, not a custom dialect

v0.2 invented a `{{var | default: "..."}}` syntax. v0.3 uses EEx —
which is in Elixir's standard library, well-known, and avoids an
extra parser:

- Variables: `<%= @focus %>`
- Defaults are expressed by setting them in front-matter, not in
  template syntax.
- Conditionals: `<% if @focus do %>...<% end %>`

The runtime constructs an assigns map from front-matter defaults
overridden by user-provided arguments, then renders via
`EEx.eval_string/2` with `engine: EEx.SmartEngine`.

### Use

```text
tet> /review focus=auth
tet> /commit-message
tet> /explain-this-file
```

`tet commands list` enumerates discovered commands. `tet commands
show <name>` prints the resolved body for inspection.

### AGENT.md

Project-level coding rules live in `<workspace>/AGENT.md`. The runtime
loads it as part of the system prompt for **all modes** (chat,
explore, execute) — coding-style and naming conventions are not
mode-specific.

A workspace may also define `.tet/prompts/system.md` to override the
default top-level system prompt. Layer order:

```text
built-in defaults → AGENT.md → workspace system.md → mode → agent profile system_prompt → user prompt
```

### Boundary

Slash commands and `AGENT.md` are inert text. They do not change tool
permissions, modes, trust, or any other policy. They only contribute
to prompt composition.

### Acceptance

- [ ] Discovery in the documented priority order; first match wins.
- [ ] EEx templating with assigns from front-matter defaults plus
      user arguments works.
- [ ] `AGENT.md` is included in chat/explore/execute prompts; absence
      is not an error.
- [ ] `tet commands list` and `tet commands show` exist.
- [ ] Conflict tests: when the same command name exists in multiple
      directories, the priority order is honored.
