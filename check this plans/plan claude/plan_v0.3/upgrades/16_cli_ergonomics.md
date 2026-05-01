# 16 — CLI Ergonomics

> **v0.3 changelog:** shell completion plan in v0.2 had every Tab press
> shell back to `tet ... --json`, which cold-starts the Elixir release
> (typically 500ms-2s) and feels broken. v0.3 uses a static cache file
> refreshed by the runtime on relevant state changes. Static command
> and option names are baked into the generated completion script;
> dynamic values come from the cache.

The original CLI command list was utilitarian. This doc adds the table
stakes of a 2026 CLI tool: machine-readable output, help, completion,
context management, clean cancellation.

## `--json` everywhere readable

Every read command supports `--json`. JSON output is the integration
surface for shells, scripts, editors, and CI.

```bash
$ tet session list . --json
[
  {"id":"01HW...","short_id":"s_8f3a21","mode":"execute",
   "status":"waiting_approval","title":"add readme note",
   "updated_at":"2026-04-29T13:35:21Z"}
]

$ tet approvals s_8f3a21 --json
[
  {"id":"01HW...","short_id":"appr_001","status":"pending",
   "files":["README.md"],"diff_artifact":"art_3b1d77",
   "size_bytes":412,"created_at":"..."}
]
```

Rules:

- `--json` and the human formatter render the same fields; tests
  assert parity.
- JSON keys are stable (snake_case, never renamed in a major version).
- Streaming commands (`tet events tail`, `tet chat`) emit JSON Lines —
  one event per line, terminated by `\n`, no surrounding array.
- Errors in `--json` mode write to stderr as a single JSON object
  `{"error":{"kind":"...","message":"...","exit_code":N}}` and the
  process exits with the documented code.

## Help and discovery

```text
tet help                      top-level help with command list
tet help <command>            command-specific help
tet <command> --help          same as above
tet --version                 version + git sha + Elixir/OTP
tet --license                 license text
```

Help text is generated from a single source: each command module
defines `@doc` plus a `usage/0` callback. The renderer produces both
human help and a `--json` listing for completion engines.

## Shell completion

Generated, not hand-written:

```text
tet completion bash > /etc/bash_completion.d/tet
tet completion zsh  > "${fpath[1]}/_tet"
tet completion fish > ~/.config/fish/completions/tet.fish
```

### Static parts (baked into the generated script)

- Subcommand names.
- Long-option names per subcommand.
- Enum values for fixed-domain options (`--mode chat|explore|execute`,
  `--strategy summary|keep`).

These don't change between releases of a given binary, so the
completion script contains them inline. Tab is instant.

### Dynamic parts (from cache file)

Sessions, approvals, agents, MCP servers, models. The completion
script reads from a cache file:

```text
~/.cache/tet/completion-cache.json
```

The runtime refreshes this file whenever the relevant entity changes:

- `tet session new` / `tet session list` → refresh `sessions`.
- `tet patch approve` / `reject` / `tet edit` → refresh `approvals`.
- `tet config set ...` / startup → refresh `agents` and `models`.

Refresh writes are atomic (`tmp` + `rename`) and bounded (~10ms to
serialize the small set the cache holds — only the last N entities
the user touched in this workspace, default N=20). The cache file
schema is versioned in its first key so an old completion script
gracefully falls back to "no dynamic values" rather than misbehaving.

If the cache is missing or stale (>24h), the completion script
silently offers static completions only. No live `tet ... --json`
calls per Tab press.

### Acceptance for completion

- [ ] First Tab returns within 50ms in steady state (static).
- [ ] Dynamic value Tab returns within 50ms in steady state (cache
      read).
- [ ] Cache invalidation tests: after `tet session new`, the new id
      appears in completion within one second.
- [ ] Stale cache is silently ignored, not surfaced as an error.

## Context management — `tet truncate`

Long sessions blow context windows. Code Puppy's `/truncate <N>` keeps
the system message + the N most recent messages. Adopted:

```text
tet truncate SESSION_ID --keep 20
```

Behavior:

- Preserves the system prompt and the most recent N user/assistant
  message pairs.
- Older messages are not deleted from the journal — they are flagged
  `included_in_prompt: false`. The audit trail stays intact.
- Emits `session.truncated` with `kept_count` and `dropped_count`.
- Default N is workspace-configurable via
  `[limits].default_keep_messages`.

For automation, `tet truncate --strategy summary` (post-v1) replaces
dropped messages with a summarization step. v1 ships the keep-N
strategy only.

## Cancellation

The facade-level `Tet.cancel/2` is in corrections §2. The CLI side:

### From inside `tet chat`

- `Ctrl-C` once: cancel current in-flight prompt, return to prompt.
- `Ctrl-C` twice within 1 second: exit the REPL.
- `Ctrl-D`: exit the REPL.

The chat REPL traps SIGINT and translates the first within-prompt
SIGINT to `Tet.cancel(session_id, :user_cancelled)`. If no prompt is
in flight, the first SIGINT falls through to exit.

### From outside

```text
tet cancel SESSION_ID                soft cancel (waits up to 5s)
tet cancel SESSION_ID --force        kills tool subprocess immediately
```

Exit codes: 0 on success, 7 if session is not running.

### Windows note

Ctrl-C semantics on Windows differ; the original Code Puppy README
recommends installing as a global tool to capture them properly. Same
recommendation applies; a `--ctrl-x-cancel` config option uses Ctrl-X
instead on Windows where SIGINT delivery is unreliable.

## Output verbosity

```text
tet ... -q                quiet (errors only)
tet ... -v                verbose (info + debug)
tet ... -vv               trace (every workflow step start/commit)
TET_LOG=debug             same as -v via env
```

Verbosity does not affect `--json` output structure; only log volume.

## Color and TTY

- Colors on for interactive TTY by default.
- `--no-color` and `NO_COLOR=1` (https://no-color.org) disable.
- Non-TTY stdout (pipes, files) → no color, no progress bars, no
  spinners.
- `--json` always implies no color/spinners.

## Progress and streaming

- `tet ask` and `tet edit` show a streaming spinner while waiting for
  the first provider token. Once tokens arrive, the spinner is
  replaced by the streaming text.
- `tet events tail` streams JSON Lines or human format depending on
  `--json`.
- `tet patch approve --watch` streams subsequent `patch.applied`,
  `verifier.started`, `verifier.finished` events until the workflow
  reaches a terminal state.

## Editor integration

Two affordances for editor extensions:

- `tet rpc` (post-v1) — JSON-RPC over stdio that wraps the `Tet.*`
  facade. Editors talk to one long-running `tet rpc` per workspace
  instead of spawning CLIs per action. Documented as future work.
- `tet events tail --json | <consumer>` — works today as a stream for
  editor sidebars.

## Examples

```bash
# Scripted: edit, wait for approval, approve programmatically
S=$(tet session new . --mode execute --json | jq -r .id)
tet edit "$S" "rename foo() to bar()"
APPR=$(tet approvals "$S" --json | jq -r '.[0].short_id')
tet patch approve "$APPR" --watch
```

```bash
# CI: dry run, no writes
S=$(tet session new . --mode explore --json | jq -r .id)
tet ask "$S" "summarize the architecture"
```

## Acceptance

- [ ] `--json` is supported on every read command and round-trips
      through `jq`.
- [ ] `tet help` and per-command `--help` are generated from a single
      source and match the `--json` usage output.
- [ ] `tet completion {bash,zsh,fish}` produces working completions
      verified by integration test in CI.
- [ ] Static completion (subcommands, options, enum values) returns
      within 50ms.
- [ ] Dynamic completion reads from
      `~/.cache/tet/completion-cache.json`; runtime writes the cache
      atomically on session/approval/agent/model changes.
- [ ] Stale or missing cache is silently ignored; no live `tet --json`
      calls per Tab press.
- [ ] `tet truncate --keep N` emits the documented event and preserves
      the journal.
- [ ] `Ctrl-C` once in `tet chat` cancels the in-flight prompt without
      exiting; twice exits.
- [ ] `tet cancel SESSION_ID` returns within 5s under default settings.
- [ ] `NO_COLOR=1` and `--no-color` honored; non-TTY stdout has no
      escape codes.
- [ ] Streaming output is JSONL (one event per line) in `--json` mode.
