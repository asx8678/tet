# 03 — CLI Commands and Modes

## Binary

```text
tet
```

Use `tet` consistently. Do not use `agent` as the primary binary or root namespace.

## Minimal v1 command set

```text
tet doctor
tet init [PATH] [--trust] [--copy-default-prompts]
tet workspace trust PATH
tet workspace info [PATH]

tet session new  PATH [--mode chat|explore|execute] [--provider NAME] [--model ID]
tet session list [PATH]
tet session show SESSION_ID

tet chat    SESSION_ID
tet ask     SESSION_ID "question"
tet explore SESSION_ID "inspect this"
tet edit    SESSION_ID "make this change"

tet approvals SESSION_ID
tet patch approve APPROVAL_ID
tet patch reject  APPROVAL_ID

tet verify SESSION_ID VERIFIER_NAME
tet status SESSION_ID
tet prompt debug SESSION_ID [--save]
tet events tail SESSION_ID
```

Reserved for later, not v1:

```text
tet daemon  tet attach  tet tui  tet web
tet prompt lab  tet plan  tet run  tet repair
tet remote  tet worker  tet memory  tet migrate
```

## Command behavior

### `tet doctor`

Checks:

- CLI binary boots;
- supported Elixir/OTP versions;
- workspace path is readable;
- `.tet/` exists or can be created;
- SQLite DB opens and migrations are current;
- prompt defaults are available;
- provider config exists when provider calls are requested;
- verifier allowlist parses;
- `git` exists when git tools are enabled;
- standalone release does not require Phoenix.

Exit 0 only if all checks pass.

### `tet init [PATH] [--trust] [--copy-default-prompts]`

Creates:

```text
PATH/.tet/
  tet.sqlite
  config.toml
  prompts/                  optional workspace overrides
  artifacts/
    diffs/
    stdout/
    stderr/
    file_snapshots/
    prompt_debug/
    provider_payload/
  cache/
```

`--trust` marks the workspace as trusted. Without trust, execute-mode writes are blocked.

### `tet workspace trust PATH`

Sets the workspace trust state to trusted for the canonical root path. Required for patch application and verification.

### `tet workspace info [PATH]`

Prints workspace id, canonical root, trust state, provider/model defaults, verifier default, and last activity.

### `tet session new PATH [--mode ...] [--provider ...] [--model ...]`

Creates a persisted session bound to a workspace. Default mode is `chat`. Prints a short id such as `s_8f3a21`.

### `tet session list [PATH]`

Lists recent sessions with id, mode, status, title/summary, and last activity.

### `tet session show SESSION_ID`

Shows metadata and the last 20 timeline events.

### `tet chat SESSION_ID`

Interactive REPL. No tools. Streams assistant text. Ctrl-D exits.

### `tet ask SESSION_ID "question"`

One-shot chat prompt. No repository access. Good for scripts and smoke tests.

### `tet explore SESSION_ID "inspect this"`

Read-only repository inspection. Allows `list_dir`, `read_file`, `search_text`, `git_status`, `git_diff`. Any write intent is blocked, persisted, and rendered with a reason.

### `tet edit SESSION_ID "make this change"`

Execute mode:

- read tools allowed;
- `propose_patch` allowed;
- patch proposal saves a diff artifact and creates a pending approval;
- CLI prints diff preview and approval id;
- exits with code 3 (`waiting_approval`).

### `tet approvals SESSION_ID`

Lists pending approvals: id, files, reason/summary, risk when available, diff artifact path, and status.

### `tet patch approve APPROVAL_ID`

Approves a pending patch and asks runtime to apply it. The CLI never applies patches directly. It may trigger the configured verifier after application.

### `tet patch reject APPROVAL_ID`

Rejects a pending patch. No file changes occur.

### `tet verify SESSION_ID VERIFIER_NAME`

Runs a named verifier from `.tet/config.toml`. No arbitrary shell strings.

### `tet status SESSION_ID`

Shows session mode/status, workspace/trust, active task, pending approval, last messages, recent tool runs, and latest verification result.

### `tet prompt debug SESSION_ID [--save]`

Renders prompt layers for the next provider call: system layer, mode layer, tool cards, retrieved context, and final messages. `--save` writes a prompt-debug artifact.

### `tet events tail SESSION_ID`

Subscribes to the event stream and renders events live.

## Modes

Modes belong to sessions. Commands must match the session mode or fail with exit code 7.

| CLI command | Required/implied mode |
|---|---|
| `tet chat`, `tet ask` | `:chat` |
| `tet explore` | `:explore` |
| `tet edit`, `tet patch approve`, `tet patch reject` | `:execute` |

### `:chat`

Conversation only. No repository access.

| Capability | Allowed |
|---|---:|
| Provider call | yes |
| Message persistence | yes |
| Event timeline | yes |
| Tools | no |
| File read/write | no |
| Command execution | no |

### `:explore`

Read-only inspection.

| Tool | Allowed |
|---|---:|
| `list_dir` | yes |
| `read_file` | yes |
| `search_text` | yes |
| `git_status` | yes |
| `git_diff` | yes |
| `propose_patch` | no |
| `apply_approved_patch` | no |
| `run_command` | no |

### `:execute`

Patch-based modifications with approval.

| Tool | Allowed |
|---|---:|
| read tools | yes |
| `propose_patch` | yes, creates pending approval |
| `apply_approved_patch` | only after approval |
| `run_command` | allowlisted verifier names only |

Required for any write or verifier:

- workspace is trusted;
- session is execute mode;
- active task exists;
- no other pending approval exists for the same session;
- patch has saved diff artifact;
- patch approval row is approved before apply.

## Exit codes

```text
0  success
1  general failure
2  policy blocked
3  waiting for approval
4  provider error
5  tool error
6  verifier failed
7  invalid CLI usage / wrong mode
8  workspace not trusted
9  workspace not initialized
```

## First milestone demo

```bash
tet init . --trust
tet doctor
S_CHAT=$(tet session new . --mode chat)
tet ask "$S_CHAT" "what does this repo do?"
S_EXPLORE=$(tet session new . --mode explore)
tet explore "$S_EXPLORE" "find the main entrypoint"
S_EXEC=$(tet session new . --mode execute)
tet edit "$S_EXEC" "add a short README note"
tet approvals "$S_EXEC"
tet patch approve appr_001
tet verify "$S_EXEC" mix_test
tet status "$S_EXEC"
```

The milestone is complete only when this script works in a real local repository using the standalone release with zero Phoenix dependencies.
