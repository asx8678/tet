# 01 — Architecture Addendum

> Updates `docs/01_architecture.md` to reflect the v0.3 supervision
> tree changes from durable execution.

## Updated supervision tree

The original `docs/01` showed:

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

v0.3 supervision tree:

```text
Tet.Application
├── Tet.Telemetry
├── Tet.Config.Loader
├── Tet.EventBus                         Registry/:pg, not Phoenix.PubSub
├── Tet.Store.Supervisor                 starts configured store adapter
├── Tet.Runtime.SessionRegistry          unique registry by session id
├── Tet.Runtime.SessionSupervisor        dispatch fanout, holds NO state
├── Tet.Runtime.WorkflowSupervisor       DynamicSupervisor for executors
├── Tet.Runtime.WorkflowRecovery         one-shot at boot; then idle
├── Tet.LLM.TaskSupervisor               bounded provider stream tasks
├── Tet.Tool.TaskSupervisor              bounded tool execution
└── Tet.Verification.TaskSupervisor      bounded verifier execution
```

## Removed

- `Tet.Agent.RuntimeSupervisor` and the agent-loop GenServers under it.
- `Tet.Runtime.SessionWorker` (was implied by SessionSupervisor in
  the original; gone in v0.3).

## Added

- **`Tet.Runtime.WorkflowSupervisor`** (DynamicSupervisor): supervises
  one `Tet.Runtime.WorkflowExecutor` GenServer per active workflow.
  Workflows that are paused for approval do not have a running
  executor — the supervisor stops them after the pause is recorded.
- **`Tet.Runtime.WorkflowRecovery`**: a one-shot module run during
  application start, after the store is up and before
  `WorkflowSupervisor` accepts new starts. Walks pending workflows,
  classifies them per the doc 12 decision tree, and either starts
  executors or marks them failed.
- **`Tet.LLM.TaskSupervisor`**: bounded provider stream tasks. Used by
  the `provider_call:attempt:N` step. Bound is configurable via
  `[providers].max_concurrent_streams` (default 4 per session).

## Changed

- **`Tet.Runtime.SessionSupervisor`** is no longer a state-holding
  per-session supervisor. It is a thin dispatch layer: when a command
  arrives for a session, it resolves `session_id → workflow_id` from
  storage, ensures a `WorkflowExecutor` is running under
  `WorkflowSupervisor`, and forwards the command. It owns no
  per-session GenServer.

## Why

The original tree assumed in-memory state per session (the
`SessionWorker`). Durable execution makes the journal authoritative,
which lets us move per-session state out of process memory entirely.
Sessions become pure data; only workflows have running processes; and
because workflows are recoverable from the journal, even those
processes are disposable.

This is what makes restart cheap (doc 13's "no hot upgrades" decision)
and what makes Phoenix LiveView's reconnect-replay model trivial
(doc 09 already required journal-driven projection; v0.3 makes it
unconditional).

## Web release tree

Unchanged from `docs/01`:

```text
TetWebPhoenix.Application
└── TetWeb.Endpoint
```

The web app supervises only its own endpoint. It calls into
`Tet.Application`'s tree through the public facade.

## One-prompt flow with v0.3 tree

```text
tet edit S "make this change"
  CLI → Tet.send_prompt(S, "...", mode: :execute)
        Tet.Runtime.dispatch(S, %Tet.Command.UserPrompt{...})
          SessionSupervisor: resolve workflow, start/attach executor
          WorkflowExecutor: run step program
            compose_prompt → commit
            provider_call:attempt:1 → spawn under LLM.TaskSupervisor
              [stream events, journal each, publish projection events]
              commit
            tool_run:propose_patch → spawn under Tool.TaskSupervisor
              [save diff artifact, create approval]
              commit; workflow.status = :paused_for_approval
              executor exits cleanly
          (no process holds state; approval is durable)
```

## Acceptance

- [ ] `Tet.Application` boots with the v0.3 supervision tree exactly.
- [ ] `Tet.Runtime.WorkflowRecovery` runs once per boot and is idle
      after.
- [ ] No process named `SessionWorker` or `Tet.Agent.RuntimeSupervisor`
      exists in the v0.3 codebase. Enforced by source guard.
- [ ] Sessions paused for approval do not retain a running executor
      process.
