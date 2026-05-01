# 12 — Durable Execution

The most important architectural change in the upgrade pack. Replaces
the original "GenServer holds in-memory state, emits events after the
fact" model with a journaled workflow whose every step is checkpointed
in storage *before* its side effect runs.

> **v0.3 changelog:** step naming pinned to a single convention
> (colons, no dots). Idempotency-key input scope spelled out per step
> type. Recovery decision tree rewritten to handle the snapshot-exists-
> but-no-files-touched case, the cancel-vs-crash race, and the
> rename/create/delete rollback cases that v0.2 hand-waved. Supervision
> tree update integrated. Made explicit that a `SessionWorker` no
> longer holds state — it is only a dispatch and event-fanout point.

## Why

A naive agent loop crashes badly: provider stream cuts mid-response →
assistant message lost. Process restart → in-flight tool runs become
orphans. User Ctrl-C → no defined behavior. Patch fails on file 3 of 5
→ workspace torn, no rollback. Two events arrive in close succession
during a crash → reorder, lose, or duplicate.

Durable execution makes all of these recoverable by treating the agent
loop as a sequence of named, idempotent steps recorded in a workflow
journal. The journal is the source of truth. Events emitted to
subscribers are *projections* of the journal for **workflow events**;
**domain events** (workspace/session lifecycle) are written directly.

This pattern is widely deployed (DBOS, Temporal, AWS Step Functions).
Code Puppy uses DBOS to wrap every agent run; we adapt the same idea
for Elixir/OTP using a journal table behind the existing `Tet.Store`
contract plus a runtime executor in `tet_runtime`.

## Vocabulary

- **Workflow.** One execution of an agent loop bound to a session and
  an active task. Has a unique `workflow_id`.
- **Step.** A single named, idempotent operation inside a workflow.
- **Step record.** A row in the journal. Has `started_at`,
  `committed_at`, `idempotency_key`, `input`, `output`, `status`
  (`:started | :committed | :failed | :cancelled`).
- **Idempotency key.** Per-step. Derived from
  `(workflow_id, step_name, hash(scoped_input))` where `scoped_input`
  is defined per step type — see §"Idempotency input scope."

## Step naming convention

Single grammar: lowercase, colon-separated, no dots:

```text
compose_prompt
provider_call:attempt:1
provider_call:attempt:2
tool_run:read_file
tool_run:propose_patch
patch_apply
patch_rollback
verifier_run:mix_test
emit_event
```

Dots are reserved for event types
(`workflow.step_committed`); steps use colons exclusively. The grammar
is enforced by a regex at insert time:
`^[a-z_]+(:[a-z0-9_]+)*$`.

## Journal storage

Lives under the existing `Tet.Store` behaviour. Two new entities:

```text
Tet.Workflow {
  id, session_id, task_id,
  status: :running | :paused_for_approval | :completed | :failed | :cancelled,
  created_at, updated_at,
  metadata
}

Tet.WorkflowStep {
  id, workflow_id,
  step_name,
  idempotency_key,           # sha256, see §"Idempotency input scope"
  input,                     # canonical JSON of step's scoped inputs
  output,                    # canonical JSON of step result, when committed
  status,
  started_at, committed_at,
  attempt,                   # 1-indexed; retry attempts each get a new key
  metadata
}
```

A unique index on `(workflow_id, idempotency_key)` enforces
exactly-once commit per logical step. A retry that recomputes the same
input hits the unique constraint and returns the committed output.

Store contract additions:

```elixir
@callback start_step(map()) :: {:ok, WorkflowStep.t()} | {:exists, WorkflowStep.t()}
@callback commit_step(binary(), output :: term()) :: {:ok, WorkflowStep.t()}
@callback fail_step(binary(), error :: term()) :: {:ok, WorkflowStep.t()}
@callback cancel_step(binary()) :: {:ok, WorkflowStep.t()}
@callback list_pending_workflows() :: {:ok, [Workflow.t()]}
@callback list_steps(workflow_id :: binary()) :: {:ok, [WorkflowStep.t()]}
@callback claim_workflow(workflow_id :: binary(), node :: atom(), ttl_ms :: pos_integer())
          :: {:ok, :claimed} | {:error, :held_by, atom()}
```

`claim_workflow` is for multi-node deployments only; single-node is
`{:ok, :claimed}` unconditionally. See doc 13 for the multi-node
story.

## Idempotency input scope

Hashing "the input" naively breaks: each provider retry would see a
different message list (the retry's prompt history excludes the failed
attempt's partial output, but other side data may still drift). We
pin the scope per step type:

| Step                          | Scoped input (the thing hashed)                                       |
| ----------------------------- | --------------------------------------------------------------------- |
| `compose_prompt`              | `{system_prompt_hash, mode, agent_profile_id, user_prompt_text, message_history_hash}` |
| `provider_call:attempt:N`     | `{compose_prompt_output_id, model, attempt}` — pinned to the previous step's output, NOT to current message list |
| `tool_run:<tool>`             | `{tool_name, canonical_args}` for read tools; `{tool_name, canonical_args, diff_sha256}` for `propose_patch` |
| `patch_apply`                 | `{approval_id, diff_sha256}` — same approval cannot apply twice       |
| `patch_rollback`              | `{approval_id}` — idempotent on rollback                              |
| `verifier_run:<name>`         | `{verifier_name, post_apply_workspace_hash_or_nil}` — same name on same workspace state is idempotent |
| `emit_event`                  | `{event_type, payload_canonical}`                                     |

`compose_prompt_output_id` is the journal id of the committed
`compose_prompt` step. This means a `provider_call` retry hashes the
same input regardless of what message list the runtime currently holds
in memory — the only authoritative input is what the previous step
journaled.

```elixir
defmodule Tet.Workflow.IdempotencyKey do
  @spec build(workflow_id :: binary(), step_name :: binary(), scoped_input :: term()) :: binary()
  def build(workflow_id, step_name, scoped_input) do
    canonical = canonical_json(scoped_input)
    :crypto.hash(:sha256, [workflow_id, "|", step_name, "|", canonical])
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(term) do
    # Sort keys recursively, encode atoms as strings via Tet.Codec when applicable.
    term |> sort_keys() |> Jason.encode!()
  end
  # ... sort_keys/1 implementation omitted
end
```

`request_id` in `Tet.LLM.Provider.request` (doc 11) is the idempotency
key for a `provider_call:attempt:N` step. A provider that already saw
`request_id` for this attempt and committed a response returns the
cached response from the journal instead of re-issuing the HTTP call.

## Executor

`Tet.Runtime.WorkflowExecutor` is a GenServer per active workflow,
supervised under `Tet.Runtime.WorkflowSupervisor` (DynamicSupervisor).
The executor is small and stateless across restarts — its in-memory
state is always reproducible by replaying the journal.

```text
1. Load workflow's step history via list_steps/1.
2. Replay committed steps to rebuild in-memory state. No side effects.
3. Pick the next step from the agent program.
4. Build idempotency key from scoped input.
5. Call start_step. If {:exists, %{status: :committed} = s}, use s.output.
6. If start_step returns a started-not-committed step from a previous
   crash, run the recovery decision tree (§"Crash recovery").
7. Otherwise execute the step's side effect.
8. On success: commit_step. On failure: fail_step + classify retryable.
9. Repeat from (3).
```

The agent program (which step to run next) is a pure function of
journal state. This separation lets us test the executor with a
deterministic agent program and test agent programs without a real
database.

## Patch application — atomic, with per-change-type rollback

The v0.2 doc handwaved rollback. Here is the actual algorithm.

### Pre-apply analysis

`Tet.Patch.parse(diff_text)` returns an ordered list of `change`
records:

```elixir
%Tet.Patch.Change{
  kind: :create | :delete | :modify | :rename | :mode_change,
  path: "lib/foo.ex",
  rename_from: nil | "lib/old_foo.ex",
  pre_mode: 0o100644 | nil,
  post_mode: 0o100644 | nil,
  pre_sha: "..." | nil,    # nil for :create
  post_sha: "..." | nil,   # nil for :delete
  hunks: [...]
}
```

### Snapshot phase

Before any write, build a snapshot dossier under
`.tet/artifacts/file_snapshots/<approval_id>/`:

```text
manifest.json              # ordered list of changes with pre-state metadata
files/<rel_path>           # byte-exact copy of pre-state for :modify, :delete, :rename, :mode_change
                           # (no entry for :create — there is no pre-state)
```

Manifest is written atomically (`tmp` + `rename`). The `manifest.json`
existing is the signal "snapshot is complete." If recovery sees the
directory but no manifest, the snapshot was interrupted; rollback is a
no-op (no files touched yet).

Snapshot phase commits a `patch_apply` step record with status
`:started` and `output: nil`. The commit itself is the durable marker
that snapshot is in flight.

### Dry-run check

```bash
git apply --check <diff>
```

Failure → reject with `:patch_does_not_apply`. No writes have happened.
Step transitions to `:failed`.

### Apply phase

Default: `git apply <diff>` (working tree only). With
`[execute].apply_to_index = true`, use `git apply --index <diff>`.
`git apply` is preferred over `patch(1)` because it handles binary
patches, file modes, renames, and creation/deletion uniformly.

If `git apply` exits non-zero after the dry run passed (rare but
possible on filesystem errors mid-write), trigger `patch_rollback`.

### Commit phase

On success: write the `patch_apply` step's `output: %{applied_files,
created_files, deleted_files, renamed_files, mode_changes}` and
transition to `:committed`. Emit `patch.applied`.

### Rollback by change type

`Tet.Patch.rollback(approval_id, manifest)`:

| Original change   | Rollback action                                                       |
| ----------------- | --------------------------------------------------------------------- |
| `:create`         | `File.rm/1` the created file. If absent, no-op.                       |
| `:delete`         | Restore from `files/<rel_path>` snapshot.                             |
| `:modify`         | Overwrite with `files/<rel_path>` snapshot.                           |
| `:rename`         | If the post-rename path exists, `File.rm/1` it. Restore the pre-rename path from snapshot. |
| `:mode_change`    | `File.chmod/2` to `pre_mode`.                                         |

Rollback is idempotent: running it twice is safe. After successful
rollback, emit `patch.rolled_back` and commit the `patch_rollback`
step with `output: %{restored: [...], reason: ...}`. The original
`patch_apply` step is marked `:failed`.

## Crash recovery

`Tet.Runtime.WorkflowRecovery.recover_pending/0` runs at supervisor
start, after `Tet.Application` has booted core/store but before
`WorkflowSupervisor` accepts new workflows.

```elixir
def recover_pending do
  for wf <- Tet.Store.list_pending_workflows!() do
    classify_and_handle(wf)
  end
end
```

### Decision tree

For each workflow with `status: :running`:

1. Find the latest step with `status: :started` and no `committed_at`.
2. If none exists, the workflow is cleanly between steps — resume.
3. Otherwise, route by `step_name`:

| Step at crash                | Recovery                                                                          |
| ---------------------------- | --------------------------------------------------------------------------------- |
| `compose_prompt`              | Idempotent (pure). Re-run; commit.                                                 |
| `provider_call:attempt:N`    | If retry budget remaining, mark step `:failed` and start `:attempt:N+1`. Else fail workflow. The HTTP call may have completed billed-but-uncommitted; the user is informed via an `error.recorded` event with `kind: :provider_uncommitted_attempt`. |
| `tool_run:<read_tool>`       | Idempotent on stable FS. Re-run; commit.                                          |
| `tool_run:propose_patch`     | Diff artifact is content-addressed by sha. If the artifact file exists with matching sha, mark step `:committed` with the existing approval id (look up by `diff_sha256`). Otherwise mark `:failed` and let the agent retry. |
| `patch_apply` — see below    |                                                                                   |
| `patch_rollback`             | Idempotent. Re-run.                                                               |
| `verifier_run:<name>`        | Process tree is gone. Re-run with same idempotency key (post-apply workspace hash matches; idempotent on stable workspace). |
| `emit_event`                 | Mark `:committed`. Subscribers may double-receive the next event delivery; clients are required to dedupe by `event.id`. |

For `patch_apply` specifically:

1. Check if `<approval_id>/manifest.json` exists.
2. If absent: snapshot was incomplete. No files were touched. Mark
   `patch_apply` step `:failed`. Workflow continues to next step
   (which is typically "report failure to user").
3. If present: snapshot was complete; `git apply` may or may not have
   started. We cannot tell from journal alone. Run `patch_rollback`
   unconditionally — it is idempotent. Mark workflow `:failed` with
   reason `:patch_torn_recovered`. Operators inspecting the workspace
   see it in pre-patch state.

### Cancel-vs-crash race

If a `cancel` was committed just before the crash (the cancel step
itself is journaled), the workflow status will already be
`:cancelled` at recovery time. `list_pending_workflows` filters those
out. No special handling needed.

### Stuck workflows

A workflow with `status: :running` and no journal updates for more
than `recovery.stuck_after_seconds` (default 600) is marked `:failed`
with reason `:stuck_after_restart`. Multi-node deployments use the
`claim_workflow` mechanism (doc 13) instead of timeouts.

## Cancellation

`Tet.cancel(session_id, reason, opts)` translates to
`%Tet.Command.Cancel{}` dispatched to the workflow executor:

1. Mark the workflow `:cancelled` in the journal (atomic single-row
   update).
2. Abort the in-flight provider stream task (`Task.shutdown/2`).
3. With `force: false` (default), wait up to 5s for the current tool
   run to finish naturally; commit or fail its step accordingly.
4. With `force: true`, kill the tool task immediately and mark its
   step `:cancelled`.
5. Emit `workflow.cancelled` and transition session status.
6. Refuse further commands for this workflow.

A new task may be started; it gets a new `workflow_id`. Cancelled
workflows are not resumable.

## Approvals as workflow pause

A workflow that proposes a patch enters `:paused_for_approval`. The
executor exits cleanly (no GenServer holding state). The
`approval.created` event fires. When the human approves or rejects via
`Tet.approve_patch/3` or `Tet.reject_patch/3`, the runtime starts a
fresh executor that loads the workflow from the journal, sees the
approval resolved, and proceeds with `patch_apply` (or terminates).
Approvals can sit indefinitely without holding any process state.

## Events: workflow projections vs. domain events

Two categories, both flowing through `Tet.EventBus`:

- **Workflow events** — listed in `Tet.Codec.workflow_event_types/0`.
  Emitted by the executor as a side effect of step commits. Their
  source of truth is the workflow journal; events are projections.
- **Domain events** — listed in `Tet.Codec.domain_event_types/0`.
  Emitted directly by `Tet.Runtime` for workspace and session
  lifecycle (`workspace.created`, `session.created`, `error.recorded`,
  etc.). These are not workflow steps; they have no idempotency key.
  They're written directly to the events table inside a transaction
  with the corresponding domain mutation.

Subscribers don't need to know the difference. `Tet.list_events/2`
returns both kinds in `seq` order.

## Supervision tree updates

The original `docs/01_architecture.md` showed:

```text
Tet.Application
├── Tet.Telemetry
├── Tet.Config.Loader
├── Tet.EventBus
├── Tet.Store.Supervisor
├── Tet.Runtime.SessionRegistry
├── Tet.Runtime.SessionSupervisor
├── Tet.Agent.RuntimeSupervisor
├── Tet.Tool.TaskSupervisor
└── Tet.Verification.TaskSupervisor
```

v0.3 supervision tree (also documented in
`addenda/01_architecture_addendum.md`):

```text
Tet.Application
├── Tet.Telemetry
├── Tet.Config.Loader
├── Tet.EventBus
├── Tet.Store.Supervisor                    starts configured store adapter
├── Tet.Runtime.SessionRegistry             unique registry by session_id
├── Tet.Runtime.SessionSupervisor           dispatch fanout, holds NO state
├── Tet.Runtime.WorkflowSupervisor          DynamicSupervisor for executors
├── Tet.Runtime.WorkflowRecovery            one-shot at boot; then idle
├── Tet.LLM.TaskSupervisor                  bounded provider stream tasks
├── Tet.Tool.TaskSupervisor                 bounded tool execution
└── Tet.Verification.TaskSupervisor         bounded verifier execution
```

`SessionWorker` from the original plan is **gone**. Its responsibilities
split:

- **Routing inbound commands** → `SessionSupervisor` resolves
  `session_id → workflow_id` from storage and starts/restarts a
  `WorkflowExecutor` under `WorkflowSupervisor`.
- **Holding session state** → no longer in process memory. Loaded from
  storage on demand by the executor and any read endpoint.
- **Fanning out events** → `Tet.EventBus` (already existed; unchanged).

This kept `Tet.Application`'s tree stable in shape; only the contents
of the per-session subtree changed.

## Configuration

```toml
[workflow]
recovery_enabled = true
stuck_after_seconds = 600
provider_max_attempts = 3
provider_retry_initial_ms = 1000
provider_retry_max_ms = 30000
tool_default_timeout_ms = 30000
patch_apply_timeout_ms = 60000
verifier_default_timeout_ms = 60000

[execute]
apply_to_index = false           # plain working-tree apply by default
```

## What this replaces

- `Tet.Agent.Runtime` (loop module) → executor consumes a step program.
- `Tet.Runtime.SessionWorker` → eliminated; see supervision tree.
- `Tet.EventBus` is no longer the source of truth for workflow events;
  it is the publication surface. The journal is the source of truth.
- "snapshot when practical" disappears; rollback is mandatory and
  recovery-driven.
- "only one pending approval per session" becomes "workflow.status =
  :paused_for_approval is exclusive per session," enforceable at the
  storage level via a partial unique index on
  `(session_id) WHERE status = 'paused_for_approval'`.

## Acceptance

- [ ] `Tet.Workflow` and `Tet.WorkflowStep` schemas live in core.
- [ ] Step name regex `^[a-z_]+(:[a-z0-9_]+)*$` enforced at insert.
- [ ] Store contract additions implemented for memory and sqlite, with
      shared contract tests.
- [ ] Unique constraint on `(workflow_id, idempotency_key)` enforces
      exactly-once commit.
- [ ] Idempotency input scope per step type matches the table; covered
      by tests asserting hash stability across retries.
- [ ] Provider call retries share a parent `compose_prompt_output_id`
      and do not double-bill on resume.
- [ ] Recovery test: kill BEAM mid-`patch_apply` after snapshot,
      before `git apply`. Restart triggers rollback (no-op) and
      workflow ends `:failed` with `:patch_torn_recovered`.
- [ ] Recovery test: kill BEAM mid-`patch_apply` after `git apply`
      starts. Restart triggers rollback that restores files. Workspace
      hash matches pre-patch state.
- [ ] Recovery test: kill BEAM mid-`provider_call:attempt:1`. Restart
      starts `:attempt:2` with the same `request_id`-relevant state.
- [ ] Cancellation test: `Tet.cancel/2` aborts in-flight stream within
      1s under default settings.
- [ ] Approval-pause test: paused workflow survives full BEAM restart
      and resumes correctly when human approves.
- [ ] Property test: replaying step history produces the same
      in-memory workflow state regardless of replay order timing.
- [ ] Rollback property test: across 100 generated diffs covering all
      five change kinds (create/delete/modify/rename/mode), running
      apply-then-rollback restores the workspace to a hash equal to
      pre-apply.
