# CLI Agent Workflow — Minimal Extensible Core Plan

This plan keeps the skeleton of the larger architecture, but removes everything that is not needed for the first working coding-agent core.

The first version should be a small, safe, local coding-agent workbench:

```text
Owl CLI → Session → Prompt Composer → Universal Agent Runtime → One LLM Provider
       → Safe local tools → Patch approval → Verification → Persisted timeline
```

The goal is not to build the full orchestration platform yet. The goal is to build the smallest core that can chat, inspect a repo, propose file edits, require approval, apply patches, and run verification.

---

## 1. What the large architecture becomes in the minimal core

| Area from big diagram | Build now | Defer until later |
|---|---|---|
| User entry / CLI interface | Owl CLI with a few commands | Full TUI, advanced attach flows, repair dashboard |
| Prompt and session layer | Session process, prompt composer, persisted messages | Prompt Lab, prompt refiner, hook runner, history compaction |
| Core agent / orchestration | One universal agent runtime | Orchestrator, planner, specialized worker agents |
| Model / provider layer | One provider adapter | Model router, per-agent model pinning, OpenRouter/Ollama routing |
| Tool layer | Local file read, search, git status/diff, patch proposal, approved patch apply, verification allowlist | Arbitrary shell, remote tools, large tool marketplace |
| Durability and memory | Sessions, messages, tool runs, approvals, artifacts, events | Bronze/Silver/Gold memory, scoring, long-term lessons |
| Web / remote execution | Optional thin LiveView mirror after CLI works | SSH control, VPS workers, remote agent sessions |
| Safe recovery | Basic blocked-action logging and smoke tests | Nano repair mode, self-healing repair tasks |

---

## 2. Minimal product definition

The first working product should do only this:

1. Create or open a local workspace.
2. Start a persisted session.
3. Accept a prompt from Owl CLI.
4. Compose a structured prompt from simple prompt files.
5. Call one LLM provider.
6. Stream the assistant response.
7. Let the agent inspect files inside the workspace.
8. Let the agent propose patch-based file edits.
9. Show the diff and wait for user approval.
10. Apply only approved patches.
11. Run an allowlisted verification command.
12. Save messages, tool runs, approvals, artifacts, and events.
13. Later, show the same session in Phoenix LiveView.

This is enough to start coding and still leaves clear extension points for the larger system.

---

## 3. Minimal architecture

```text
┌────────────────────┐
│      Owl CLI        │
│ doctor/chat/edit    │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│  Session Service    │
│ sessions/messages   │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│  Prompt Composer    │
│ prompt files + mode │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│ Universal Agent     │
│ one runtime loop     │
└──────┬───────┬──────┘
       │       │
       │       ▼
       │  ┌────────────────────┐
       │  │ Local Tool Layer    │
       │  │ read/search/patch   │
       │  └─────────┬──────────┘
       │            ▼
       │  ┌────────────────────┐
       │  │ Policy + Approval   │
       │  │ path/mode/diff gate │
       │  └────────────────────┘
       │
       ▼
┌────────────────────┐
│ One LLM Provider    │
│ stream_chat/3       │
└────────────────────┘

Everything persists to Postgres through Ecto:
workspaces, sessions, tasks, messages, tool_runs, approvals, artifacts, events.
```

The important design choice: the CLI, future LiveView, and future remote workers should all call the same application services. Do not put business logic inside the CLI commands.

---

## 4. Minimal CLI commands

Build these first:

```text
agent doctor
agent workspace trust PATH
agent session new PATH
agent chat SESSION_ID
agent edit SESSION_ID "make this change"
agent approvals SESSION_ID
agent approve APPROVAL_ID
agent reject APPROVAL_ID
agent status SESSION_ID
agent prompt debug SESSION_ID
```

Do not build these yet:

```text
agent prompt lab
agent plan
agent run
agent attach
agent repair
agent remote
agent worker
```

Those names can remain reserved for later so the CLI shape can grow without changing the core model.

---

## 5. Minimal modes

Use three modes from the start because they make permissions simple.

### Chat

Assistant response only. No tools.

Use for questions, explanations, and brainstorming.

### Explore

Read-only tools only.

Use for repository inspection and planning. No file writes.

### Execute

Read tools, patch proposal, patch approval, patch apply, and verification commands.

Requirements:

- trusted workspace
- active task
- write approval
- allowlisted verification command

---

## 6. Minimal database model

Keep the schema small.

### `workspaces`

Tracks a local project root.

Important fields:

- `name`
- `root_path`
- `trust_state` — `untrusted | trusted`

### `sessions`

Tracks a CLI or LiveView conversation.

Important fields:

- `workspace_id`
- `title`
- `mode` — `chat | explore | execute`
- `status` — `idle | running | waiting_approval | complete | error`
- `provider`
- `model`
- `active_task_id`

### `tasks`

Keep this intentionally simple. One active task is enough.

Important fields:

- `session_id`
- `title`
- `status` — `active | complete | cancelled`

### `messages`

Stores conversation turns.

Important fields:

- `session_id`
- `role` — `user | assistant | system | tool`
- `content`
- `metadata`

### `tool_runs`

Stores read tools, proposed write tools, blocked tools, and verification runs.

Important fields:

- `session_id`
- `task_id`
- `tool_name`
- `args`
- `status` — `proposed | blocked | waiting_approval | running | success | error`
- `read_or_write` — `read | write`
- `block_reason`
- `changed_files`

### `approvals`

Stores pending patch approvals.

Important fields:

- `session_id`
- `task_id`
- `tool_run_id`
- `status` — `pending | approved | rejected`
- `diff_artifact_id`
- `reason`
- `resolved_at`

### `artifacts`

Stores larger generated outputs.

Important fields:

- `session_id`
- `kind` — `diff | stdout | stderr | file_snapshot | prompt_debug`
- `content`
- `path`
- `sha256`
- `metadata`

### `events`

A durable session timeline for CLI replay and future LiveView.

Important fields:

- `session_id`
- `type`
- `payload`

Do not implement full event sourcing. Use events as a timeline only.

---

## 7. Minimal Elixir module map

Use names like these. The exact app namespace can change.

```text
lib/agent_app/
  application.ex
  repo.ex

  cli/
    main.ex
    doctor.ex
    workspace_commands.ex
    session_commands.ex
    approval_commands.ex
    status_commands.ex

  sessions/
    sessions.ex
    workspace.ex
    session.ex
    task.ex
    message.ex
    tool_run.ex
    approval.ex
    artifact.ex
    event.ex

  prompting/
    composer.ex
    prompt_file_store.ex
    tool_cards.ex

  agent/
    runtime.ex
    loop.ex
    response_parser.ex
    context_builder.ex

  llm/
    provider.ex
    providers/primary.ex

  tools/
    registry.ex
    local_fs.ex
    search.ex
    git.ex
    patch.ex
    command_runner.ex

  policy/
    policy.ex
    path_policy.ex
    mode_policy.ex
    approval_policy.ex
    redactor.ex
```

Future Phoenix LiveView can be added under:

```text
lib/agent_app_web/live/
  dashboard_live.ex
  session_live.ex
  approval_live.ex
```

---

## 8. Minimal prompt system

Do not build Prompt Lab yet. Start with prompt files.

```text
priv/prompts/system.md
priv/prompts/mode_chat.md
priv/prompts/mode_explore.md
priv/prompts/mode_execute.md
priv/prompts/tool_cards.md
```

The composer should return both provider messages and debug layers:

```elixir
%{
  messages: provider_messages,
  debug_layers: [
    %{name: "system", source: "priv/prompts/system.md", content: system_text},
    %{name: "mode", source: "priv/prompts/mode_execute.md", content: mode_text},
    %{name: "tools", source: "priv/prompts/tool_cards.md", content: tool_text}
  ]
}
```

Prompt file edits should take effect on the next prompt during development.

---

## 9. Minimal tools

### Read tools

```text
list_dir(path)
read_file(path)
search_text(query, path)
git_status()
git_diff()
```

### Write tools

```text
propose_patch(diff)
apply_approved_patch(approval_id)
```

Patch-based writes are the only write path in the first core.

### Verification tool

```text
run_command(command_name)
```

`command_name` maps to an allowlist:

```elixir
%{
  "mix_format" => ["mix", "format"],
  "mix_test" => ["mix", "test"],
  "mix_compile" => ["mix", "compile", "--warnings-as-errors"],
  "npm_test" => ["npm", "test"],
  "cargo_check" => ["cargo", "check"]
}
```

Do not allow arbitrary shell commands yet.

---

## 10. Minimal policy rules

Implement this before any write tool exists.

1. No file access outside `workspace.root_path`.
2. No write tools in `chat` mode.
3. No write tools in `explore` mode.
4. No write tools unless workspace is trusted.
5. No write tools unless there is an active task.
6. No write tools without creating a diff artifact first.
7. No patch apply without an approved approval row.
8. No command execution except allowlisted verifier names.
9. Save blocked attempts as `tool_runs`.
10. Redact secrets before showing logs, artifacts, or CLI output.

This can be one small policy module at first. Do not build a hook engine yet.

---

## 11. Minimal universal agent loop

For each user prompt:

1. Save the user message.
2. Load the session and workspace.
3. Compose prompt layers.
4. Call the provider.
5. Stream assistant text to the CLI.
6. Parse any structured tool intent.
7. Run policy checks.
8. Execute read tools immediately.
9. For write tools, create a diff artifact and pending approval.
10. Stop if approval is required.
11. After approval, apply the patch.
12. Run the verifier if configured.
13. Save the final assistant message.
14. Emit session events for timeline replay.

Hard limits for the first version:

- max 6 tool iterations per prompt
- max 1 pending approval at a time
- max file read size, for example 256 KB
- max patch size, for example 500 KB
- max verifier runtime, for example 60 seconds

---

## 12. Provider adapter

Start with one provider and one model from environment config.

```elixir
defmodule AgentApp.LLM.Provider do
  @callback stream_chat(messages :: list(), opts :: map(), on_event :: function()) ::
              {:ok, map()} | {:error, term()}
end
```

Normalize provider events to:

```elixir
{:text_delta, binary}
{:tool_call, map}
{:usage, map}
{:done, map}
{:error, term}
```

Do not build model routing yet. Add it later behind this same behavior.

---

## 13. Build order

### Phase 0 — Project skeleton

Build:

- Phoenix app with Ecto/Postgres
- Owl dependency and CLI entrypoint
- app config
- provider API key from environment
- basic migrations
- `agent doctor`

Done when:

- app boots
- database migrates
- `agent doctor` checks DB, provider config, and local workspace access

### Phase 1 — Sessions and CLI chat

Build:

- workspaces, sessions, messages, events
- `workspace trust PATH`
- `session new PATH`
- `chat SESSION_ID`
- prompt composer
- one provider adapter
- streaming assistant response in CLI

Done when:

- user can create a session
- user can chat from terminal
- messages persist
- prompt debug works

### Phase 2 — Explore mode and read tools

Build:

- mode handling
- tool registry
- path policy
- `list_dir`, `read_file`, `search_text`, `git_status`, `git_diff`
- tool run persistence

Done when:

- agent can inspect files inside the workspace
- outside-root reads are blocked
- CLI shows tool activity

### Phase 3 — Execute mode and patch approvals

Build:

- tasks
- diff artifacts
- approvals
- `edit SESSION_ID "change"`
- `approvals SESSION_ID`
- `approve APPROVAL_ID`
- `reject APPROVAL_ID`
- `propose_patch`
- `apply_approved_patch`

Done when:

- agent can propose a patch
- CLI shows the diff
- patch waits for approval
- approved patch changes files
- rejected patch does nothing

### Phase 4 — Verification and local reload loop

Build:

- command allowlist
- verifier command per workspace
- `run_command(command_name)`
- stdout/stderr artifacts
- file-change events
- `status SESSION_ID`

Done when:

- approved patch triggers verification
- verification output is visible in CLI
- prompt file edits affect the next turn

### Phase 5 — Thin Phoenix LiveView mirror

Build only after CLI works:

- session page
- transcript
- tool activity
- pending approval panel
- diff preview
- verification output
- prompt debug drawer

Done when:

- the same session can be used from CLI and browser
- approvals can be completed from browser or CLI

### Phase 6 — Core hardening

Build:

- path traversal tests
- blocked write tests
- redaction tests
- provider error handling
- patch apply failure handling
- CLI smoke tests
- LiveView smoke tests if LiveView exists

Done when:

- unsafe reads/writes are blocked
- write without approval is impossible
- verifier failures are captured clearly
- session can recover from provider/tool errors

---

## 14. Future extension plan

Add these only after the minimal core is stable.

### Prompt Lab and prompt refinement

Add:

- prompt versioning
- prompt scoring
- prompt comparison
- reusable prompt experiments
- user-editable prompt profiles

Do not change the agent runtime. Extend `Prompting.Composer` and artifact storage.

### Planner and orchestrator

Add:

- plan generation
- task graph
- approval gate between planning and execution
- planner/executor split

Do not replace the universal runtime. Add orchestration above it.

### Specialized worker agents

Add:

- retriever
- reviewer
- critic
- coder
- tester

Do not add them first. They should use the same provider interface, same tools, same policy checks, and same event stream.

### Model routing

Add:

- model router
- multiple providers
- per-agent model settings
- local model support

Do this behind the existing `LLM.Provider` behavior.

### Remote execution

Add:

- SSH profiles
- remote workspace registration
- VPS worker
- remote command execution
- remote file sync

Remote tools should use the same tool registry interface as local tools.

### Durability and memory

Add:

- Bronze events
- Silver scoring
- Gold memory
- lesson promotion
- reusable repair notes

Keep `events` as the base timeline. Add memory on top.

### Safe recovery / self-healing

Add:

- repair mode
- diagnose command
- compile command
- patch command
- smoke test command

This should reuse the same patch approval and verification flow.

---

## 15. Minimal acceptance checklist

The minimal core is finished when this works:

- [ ] `agent doctor` passes.
- [ ] workspace can be trusted.
- [ ] session can be created for a workspace.
- [ ] CLI chat streams assistant output.
- [ ] messages are persisted.
- [ ] prompt layers can be debugged.
- [ ] agent can read files inside the workspace.
- [ ] agent cannot read outside the workspace.
- [ ] agent can propose a patch.
- [ ] patch is shown as a diff.
- [ ] write requires approval.
- [ ] approved patch applies to disk.
- [ ] rejected patch does not change files.
- [ ] verifier runs only from allowlist.
- [ ] verification output is saved and shown.
- [ ] events provide a replayable timeline.
- [ ] future LiveView can read the same session state.

---

## 16. Final recommendation

Start coding the minimal core as a CLI-first Phoenix/Ecto application with Owl, one universal agent runtime, one prompt composer, one provider adapter, local safe tools, patch approval, verification, and a durable event timeline.

Keep the big architecture as the north star, but do not implement orchestration, specialized agents, Prompt Lab, remote execution, self-healing, or memory scoring until the local patch-and-verify loop works end-to-end.
