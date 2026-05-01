# Final Ultimate Plan — Tet Standalone CLI + Elixir/OTP Core + Optional Phoenix LiveView

## Executive decision

Build Tet as a **standalone Elixir/OTP coding-agent runtime with the CLI as the default product**. Phoenix LiveView is optional. It may render sessions and send commands, but it must never own runtime state, policies, storage, providers, patching, verification, or the approval lifecycle.

```text
Tet must run through Elixir/OTP, not through Phoenix.
Phoenix may render and control Tet, but Tet must never be owned by Phoenix.
```

## Final source-plan resolution

Use the GPT/Tet plan for the product identity and top-level boundary, and use the Claude plan for the detailed implementation guardrails. The final plan intentionally fixes two conflicts from the Claude plan:

1. Use `Tet`, not `Agent`, because `Agent` conflicts with Elixir's built-in `Agent` module.
2. Put the public `Tet` facade in `tet_runtime`, not `tet_core`, because a core facade delegating to runtime would make core depend outward on runtime.

## Final umbrella layout

```text
tet_umbrella/
  mix.exs
  config/
  tools/
  apps/
    tet_core/             # pure domain structs, commands, events, policies, behaviours
    tet_runtime/          # OTP app, public Tet facade, sessions, event bus, tools, providers
    tet_cli/              # standalone CLI/escript/release entrypoint
    tet_store_memory/     # test adapter
    tet_store_sqlite/     # default standalone local SQLite adapter
    tet_store_postgres/   # optional server/team adapter
    tet_web_phoenix/      # optional LiveView adapter, post-v1
```

Optional provider adapters may live inside `tet_runtime` for v1 or become separate `tet_provider_*` apps later.

## Dependency direction

```text
tet_cli ----------┐
                  ├──► tet_runtime ───► tet_core
tet_web_phoenix --┘          │
                             ▼
                 configured store/provider/tool adapters
                             │
                             ▼
                          tet_core
```

Forbidden everywhere outside `tet_web_phoenix`: Phoenix, Phoenix.LiveView, Phoenix.PubSub, Plug, Cowboy, `TetWeb.*`.

## Public API boundary

All user interfaces call `Tet.*` from `apps/tet_runtime/lib/tet.ex`:

```elixir
Tet.init_workspace(path, opts)
Tet.trust_workspace(ref, opts)
Tet.start_session(workspace_ref, opts)
Tet.send_prompt(session_id, prompt, opts)
Tet.list_approvals(session_id, filter)
Tet.approve_patch(session_id, approval_id, opts)
Tet.reject_patch(session_id, approval_id, opts)
Tet.run_verification(session_id, verifier_name, opts)
Tet.subscribe(session_id)
Tet.list_events(session_id, opts)
Tet.lookup(kind, short_id, opts)
Tet.prompt_debug(session_id, opts)
Tet.doctor(workspace_ref)
```

CLI and Phoenix may pattern-match on `%Tet.Event{}` and other core structs. They may not call `Tet.Runtime.*`, `Tet.Store.*`, `Tet.Tools.*`, `Tet.EventBus.*`, or provider internals.

## CLI product

Build these commands first:

```text
tet doctor
tet init [PATH] [--trust] [--copy-default-prompts]
tet workspace trust PATH
tet workspace info [PATH]
tet session new PATH [--mode chat|explore|execute] [--provider NAME] [--model ID]
tet session list [PATH]
tet session show SESSION_ID
tet chat SESSION_ID
tet ask SESSION_ID "question"
tet explore SESSION_ID "inspect this"
tet edit SESSION_ID "make this change"
tet approvals SESSION_ID
tet patch approve APPROVAL_ID
tet patch reject APPROVAL_ID
tet verify SESSION_ID VERIFIER_NAME
tet status SESSION_ID
tet prompt debug SESSION_ID [--save]
tet events tail SESSION_ID
```

Do not build `tet web`, daemon mode, planner, workers, repair, remote execution, or Prompt Lab before the standalone CLI works.

## Modes

| Tool | Chat | Explore | Execute |
|---|:---:|:---:|:---:|
| `list_dir` | block | allow | allow |
| `read_file` | block | allow | allow |
| `search_text` | block | allow | allow |
| `git_status` | block | allow | allow |
| `git_diff` | block | allow | allow |
| `propose_patch` | block | block | allow → pending approval |
| `apply_approved_patch` | block | block | allow only after approval |
| `run_command` | block | block | allowlisted only |

Execute writes require trusted workspace, active task, no other pending approval, a saved diff artifact, and an approved approval row.

## Local storage

Default standalone layout:

```text
repo-root/.tet/
  tet.sqlite
  config.toml
  prompts/
  artifacts/
    diffs/
    stdout/
    stderr/
    file_snapshots/
    prompt_debug/
    provider_payload/
  cache/
```

Core entities: workspaces, sessions, tasks, messages, tool runs, approvals, artifacts, events. Events are a durable timeline with per-session sequence numbers.

Storage adapters implement the same `Tet.Store` behaviour:

```text
Tet.Store.Memory     tests
Tet.Store.SQLite     default standalone
Tet.Store.Postgres   optional server/team mode
```

## Safety workflow

```text
agent proposes unified diff
  -> policy validates mode/trust/path/size/task/pending approval
  -> diff artifact is saved
  -> pending approval is created
  -> CLI or optional Phoenix shows the diff
  -> user approves or rejects through Tet.*
  -> runtime applies approved patch only if it still applies cleanly
  -> allowlisted verifier may run
  -> events, tool runs, artifacts, and verifier output are persisted
```

Blocked tool intents are persisted as blocked tool runs with reason atoms.

## Verification

`run_command(verifier_name)` accepts only names from `.tet/config.toml`:

```toml
[verification.allowlist]
mix_format  = ["mix", "format"]
mix_test    = ["mix", "test"]
mix_compile = ["mix", "compile", "--warnings-as-errors"]
npm_test    = ["npm", "test"]
cargo_check = ["cargo", "check"]
```

No arbitrary shell strings. All verifier output is stored as artifacts and redacted before display.

## Release profiles

### `tet_standalone`

Includes `tet_core`, `tet_runtime`, `tet_cli`, `tet_store_sqlite`, selected provider adapter. Excludes Phoenix, LiveView, Plug, Cowboy, and `tet_web_phoenix`.

### `tet_web`

Includes optional `tet_web_phoenix` plus the same runtime/core/store. Phoenix is present only through the web app.

### `tet_runtime_only`

Includes core/runtime/store for embedding or future non-CLI adapters.

## Build order

1. Phase 0 — umbrella skeleton and guards.
2. Phase 1 — core structs, commands, events, policies, behaviours.
3. Phase 2 — runtime supervision, public `Tet` facade, event bus, session workers.
4. Phase 3 — memory/sqlite stores, `.tet/` init, config, artifacts.
5. Phase 4 — CLI foundation.
6. Phase 5 — chat mode, prompt composer, provider, prompt debug.
7. Phase 6 — explore mode and read tools.
8. Phase 7 — execute mode, patch proposal, approvals, approved patch apply.
9. Phase 8 — verifier loop.
10. Phase 9 — hardening and acceptance tests.
11. Phase 10 — optional Phoenix adapter.
12. Phase 11 — release profiles.

## Acceptance gates

The plan is accepted only when:

```bash
MIX_ENV=prod mix release tet_standalone --overwrite
_build/prod/rel/tet_standalone/bin/tet doctor
```

works and the release has no web framework closure.

The first milestone script must work in a real repo:

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

CI must also prove:

- no forbidden xref edges;
- no forbidden source references;
- runtime boots without endpoint;
- release closure contains no Phoenix/Plug/Cowboy/LiveView;
- UI apps call only `Tet.*`;
- `tet_web_phoenix` can be removed without breaking standalone compile/test/release.

## Final success condition

The redesign is complete when `tet_standalone` is a fully usable CLI coding-agent release and Phoenix is demonstrably optional: adding `tet_web_phoenix` provides a browser UI over the same sessions/events/approvals, but removing it changes nothing about the standalone runtime.
