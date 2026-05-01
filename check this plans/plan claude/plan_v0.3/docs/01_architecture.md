# 01 — Architecture

## Goal

Build a local-first coding-agent workbench that runs as a standalone Elixir/OTP CLI product. Phoenix LiveView is optional and must never be required by the CLI, runtime, core, storage, policy, patch, provider, or verification paths.

## Architectural rule

```text
CLI commands and LiveViews parse user intent and render output.
Tet runtime/core performs all state changes, policy decisions, tool execution,
prompt composition, persistence, patch application, and verification.
```

## Top-level shape

```text
                         ┌──────────────────────────────────────┐
                         │              tet_cli                 │
                         │ default standalone terminal product  │
                         └──────────────────┬───────────────────┘
                                            │ calls Tet.*
                                            ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                              tet_runtime                                 │
│ public Tet facade · OTP app · session workers · event bus · prompt       │
│ composer · provider orchestration · tools · patch applier · verifier     │
└──────────────────────────────────────┬───────────────────────────────────┘
                                       │ uses pure contracts
                                       ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                                tet_core                                  │
│ domain structs · commands · events · policies · approval state machine   │
│ LLM provider behaviour · tool behaviour · store behaviour · errors       │
└───────────────┬──────────────────────┬──────────────────────┬────────────┘
                │                      │                      │
                ▼                      ▼                      ▼
      ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
      │ tet_store_memory │   │ tet_store_sqlite │   │ tet_store_postgres│
      │ tests            │   │ default local    │   │ optional server   │
      └──────────────────┘   └──────────────────┘   └──────────────────┘

Optional driving adapter:

                         ┌──────────────────────────────────────┐
                         │          tet_web_phoenix             │
                         │ LiveViews · components · endpoint    │
                         │ calls Tet.* only                     │
                         └──────────────────┬───────────────────┘
                                            │ calls same API
                                            ▼
                                      tet_runtime
```

## App ownership

### `tet_core`

Pure library. No GenServers, no supervision tree, no Ecto, no Phoenix, no Plug, no LiveView, no terminal rendering.

Owns:

- `Tet.Workspace`, `Tet.Session`, `Tet.Task`, `Tet.Message`, `Tet.ToolRun`, `Tet.Approval`, `Tet.Artifact`, `Tet.Event` structs;
- `Tet.Command.*` structs;
- `Tet.Policy.*` semantics and reason atoms;
- `Tet.Patch` validation model and `Tet.Patch.Approval` state-machine helpers;
- `Tet.LLM.Provider` behaviour;
- `Tet.Tool` behaviour;
- `Tet.Store` behaviour;
- `Tet.Error`, `Tet.Ids`, `Tet.Redactor`.

Core may define policy contracts and pure validators. Runtime performs side-effect-heavy work such as filesystem symlink resolution, tool execution, provider calls, storage writes, and event publication.

### `tet_runtime`

The OTP application and orchestration layer. This app owns all supervised side effects and exposes the public `Tet` facade.

Owns:

- `Tet` public facade (`apps/tet_runtime/lib/tet.ex`);
- `Tet.Application` supervision tree;
- `Tet.Runtime` command dispatcher;
- `Tet.Runtime.SessionRegistry` and session supervisors;
- `Tet.Runtime.SessionWorker`;
- `Tet.Agent.Runtime` agent loop;
- `Tet.EventBus` using Registry or `:pg`, not Phoenix.PubSub;
- `Tet.Prompt.Composer` and prompt debug;
- provider adapters or provider-adapter loader;
- concrete tool implementations;
- path resolver and tool executor;
- patch applier;
- verification runner;
- store supervisor/adapter dispatcher;
- telemetry.

### `tet_cli`

Thin terminal adapter. It parses args, renders events, and exits with deterministic status codes.

It must not:

- apply patches directly;
- enforce policy directly;
- call providers;
- write storage rows directly;
- compose prompts;
- depend on Phoenix or the web app;
- call runtime internals beyond the `Tet.*` facade.

### `tet_store_memory`

In-memory adapter for tests and contract checks. Uses ETS or process state. Depends only on `tet_core`.

### `tet_store_sqlite`

Default standalone store. Implements `Tet.Store` via SQLite, usually with Ecto. Owns migrations, schema mapping, local artifact helpers, and repo supervision. Depends on `tet_core`, Ecto/SQLite libraries, and no runtime/UI code.

### `tet_store_postgres`

Optional adapter for hosted/team mode. Implements the same `Tet.Store` contract. It is not required for v1.

### `tet_provider_*`

Optional provider adapter apps may be introduced when provider dependencies become heavy. V1 may keep one provider implementation under `tet_runtime`, but the behaviour lives in `tet_core` and provider payloads are normalized before runtime logic sees them.

### `tet_web_phoenix`

Optional Phoenix LiveView adapter. It renders timeline, transcript, diffs, approvals, verifier output, and prompt debug. It calls `Tet.*` and receives `%Tet.Event{}` messages. It owns no policies, no patch logic, no provider calls, no storage semantics, and no runtime supervision for Tet sessions.

## Standalone supervision tree

```text
Tet.Application
├── Tet.Telemetry
├── Tet.Config.Loader
├── Tet.EventBus                         Registry/:pg, not Phoenix.PubSub
├── Tet.Store.Supervisor                 starts configured store adapter
├── Tet.Runtime.SessionRegistry          unique registry by session id
├── Tet.Runtime.SessionSupervisor        DynamicSupervisor
├── Tet.Agent.RuntimeSupervisor          DynamicSupervisor for agent loops
├── Tet.Tool.TaskSupervisor              bounded tool execution
└── Tet.Verification.TaskSupervisor      bounded verifier execution
```

No Phoenix endpoint appears in this tree.

The web release starts a separate optional tree:

```text
TetWebPhoenix.Application
└── TetWeb.Endpoint
```

## Runtime flow for one prompt

```text
1. User runs: tet edit S "make this change"
2. CLI resolves ids and calls Tet.send_prompt(session_id, prompt, mode: :execute)
3. Tet facade dispatches %Tet.Command.UserPrompt{} into Tet.Runtime
4. Runtime persists user message and emits message.user.saved
5. Prompt composer builds provider messages from system/mode/tool/context layers
6. Provider streams normalized events: text_delta, tool_call, usage, done, error
7. Tool calls go through Tet.Policy.check_tool/1
8. Read tools execute when allowed; blocked tools are persisted as blocked
9. propose_patch saves diff artifact + pending approval without touching files
10. User approves/rejects through CLI or optional Phoenix, both via Tet.*
11. Runtime applies only approved patches and optionally runs allowlisted verifier
12. Events and artifacts are persisted and published to subscribers
```

CLI and Phoenix differ only in parsing/rendering. Steps 3–12 are shared.

## Non-goals for v1

Do not build these before the standalone CLI works end to end:

- Phoenix dashboard;
- daemon/socket attach mode;
- TUI;
- Prompt Lab;
- planner/orchestrator/task graph;
- specialized worker agents;
- remote execution or SSH workers;
- arbitrary shell/network tools;
- package installation tools;
- long-term memory scoring;
- self-healing repair system;
- Postgres beyond a stub/contract target.
