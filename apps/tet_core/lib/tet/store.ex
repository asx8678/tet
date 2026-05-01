defmodule Tet.Store do
  @moduledoc """
  Store adapter behaviour owned by the core boundary.

  This is the v0.3 storage seam from §04, with the durable workflow journal
  additions from §12 and the scaffold-era compatibility callbacks kept until
  Phase 2 migrates runtime callers. Concrete store apps map their schemas to the
  core structs here; Ecto schemas, JSONL rows, or SQLite tables do **not** become
  the domain model.

  Contract invariants:

  - IDs are opaque `String.t()` values. Current prefixed IDs (`ses_...`,
    `msg_...`) and future UUID text both fit; the behaviour does not enforce a
    UUID format.
  - Events are a durable, per-session monotonic timeline (§04). `list_events/2`
    therefore takes a non-null `session_id`; workspace-global event feeds need a
    separate future contract, not `nil` smuggled through this one.
  - State changes that emit durable events must be atomic from the adapter's
    point of view. Ecto-backed adapters should implement that with one
    transaction / `Ecto.Multi`; SQLite's single writer owns the equivalent
    transaction boundary.
  - At most one approval may be `:pending` per session (§04). The behaviour
    states the semantic invariant; durable adapters should enforce it with a
    race-free storage constraint, not only an application pre-check.
  - At most one `Tet.Workflow` per session may have
    `status: :paused_for_approval` (§12). Durable adapters should enforce it
    with a partial unique index.
  - Artifacts are content-addressable by `sha256`; inline content and file-path
    spillover are storage choices, but the sha travels with the entity (§04).
  - Durable execution truth lives in `Tet.Workflow` and `Tet.WorkflowStep` rows,
    not in a `GenServer`'s memory palace (§12).

  Both §04 and §12 callbacks use the unified `result(value) :: {:ok, value} |
  {:error, error()}` convention for adapter consistency. See
  `docs/adr/0010-store-callback-return-convention.md`.

  Compatibility callbacks are documented below and marked optional. They remain
  available while scaffold runtime migrates; §04-conformant adapters may skip
  them if they do not support the legacy callsites.
  """

  @type id :: String.t()
  @type workspace_id :: id()
  @type session_id :: id()
  @type task_id :: id()
  @type tool_run_id :: id()
  @type approval_id :: id()
  @type artifact_id :: id()
  @type workflow_id :: id()
  @type workflow_step_id :: id()

  @type attrs :: map()
  @type update_attrs :: map()
  @type options :: keyword()
  @type error :: term()
  @type result(value) :: {:ok, value} | {:error, error()}

  @type workspace :: Tet.Workspace.t()
  @type session :: Tet.Session.t()
  @type task :: Tet.Task.t()
  @type message :: Tet.Message.t()
  @type tool_run :: Tet.ToolRun.t()
  @type approval :: Tet.Approval.t()
  @type artifact :: Tet.Artifact.t()
  @type event :: Tet.Event.t()
  @type persisted_event :: Tet.Event.persisted_t()
  @type workflow :: Tet.Workflow.t()
  @type workflow_step :: Tet.WorkflowStep.t()
  @type checkpoint :: Tet.Checkpoint.t()
  @type error_log :: Tet.ErrorLog.t()
  @type repair :: Tet.Repair.t()

  @type workspace_attrs :: attrs()
  @type session_attrs :: attrs()
  @type task_attrs :: attrs()
  @type message_attrs :: attrs()
  @type tool_run_attrs :: attrs()
  @type approval_attrs :: attrs()
  @type artifact_attrs :: attrs()
  @type event_attrs :: attrs()
  @type workflow_attrs :: attrs()
  @type workflow_step_attrs :: attrs()
  @type checkpoint_attrs :: attrs()
  @type error_log_attrs :: attrs()
  @type repair_attrs :: attrs()
  @type repair_status :: Tet.Repair.status()

  @type trust_state :: Tet.Workspace.trust_state()
  @type approval_resolution :: :approved | :rejected
  @type workflow_status :: Tet.Workflow.status()
  @type step_output :: term()
  @type step_error :: term()
  @type transaction_fun :: (-> term())

  @type health :: %{
          required(:application) => atom(),
          required(:adapter) => module(),
          required(:status) => atom(),
          optional(:path) => binary(),
          optional(atom()) => term()
        }

  @doc "Returns adapter boundary metadata for doctor/debug surfaces."
  @callback boundary() :: map()

  @doc "Returns adapter health without mutating domain state."
  @callback health(options()) :: result(health())

  @doc """
  Runs an adapter-owned transaction. Required by v0.3 §04.

  Semantics:

  - Adapters MUST treat `fun` as one atomic unit.
  - If `fun` returns `{:ok, value}`, commit and return `{:ok, value}`.
  - If `fun` returns `{:error, reason}`, roll back and return `{:error, reason}`.
  - If `fun` returns any other value, commit and return `{:ok, value}`.
  - If `fun` raises or throws, roll back. Adapters may either propagate the
    raise/throw or normalize it as `{:error, {:caught, kind, reason}}`.
  - Nested store callbacks inside `fun` MUST execute in the same transaction
    context; adapters must not re-enter a writer GenServer for those nested
    calls. Yes, re-entering your own writer is how you summon deadlocks.
  - `fun` MUST NOT perform long-running work such as provider calls or file I/O
    beyond the database transaction's own reads/writes. Transaction locks are
    not a place to take a scenic hike.
  """
  @callback transaction(transaction_fun()) :: result(term())

  @doc "Creates a workspace row from attrs."
  @callback create_workspace(workspace_attrs()) :: result(workspace())

  @doc "Fetches one workspace by id."
  @callback get_workspace(workspace_id()) :: result(workspace())

  @doc "Sets workspace trust to `:trusted` or `:untrusted`."
  @callback set_trust(workspace_id(), trust_state()) :: result(workspace())

  @doc "Creates a session row from attrs."
  @callback create_session(session_attrs()) :: result(session())

  @doc "Updates one session by id."
  @callback update_session(session_id(), update_attrs()) :: result(session())

  @doc "Fetches one session by id."
  @callback get_session(session_id()) :: result(session())

  @doc "Lists sessions for a workspace. Legacy opts-shaped callers must adapt in Phase 2."
  @callback list_sessions(workspace_id()) :: result([session()])

  @doc "Deprecated compatibility session listing by opts for scaffold-era callers."
  @callback list_sessions_with_opts(options()) :: result([session()])

  @doc "Creates a task row from attrs."
  @callback create_task(task_attrs()) :: result(task())

  @doc "Appends a final persisted message. Streaming deltas are events, not messages."
  @callback append_message(message_attrs()) :: result(message())

  @doc "Records a tool run, including blocked tool calls."
  @callback record_tool_run(tool_run_attrs()) :: result(tool_run())

  @doc "Updates one tool run by id."
  @callback update_tool_run(tool_run_id(), update_attrs()) :: result(tool_run())

  @doc "Creates an approval. Adapters must reject a second pending approval for the same session."
  @callback create_approval(approval_attrs()) :: result(approval())

  @doc "Resolves an approval as `:approved` or `:rejected`."
  @callback resolve_approval(approval_id(), approval_resolution(), update_attrs()) ::
              result(approval())

  @doc "Fetches one approval by id."
  @callback get_approval(approval_id()) :: result(approval())

  @doc "Lists approvals for a session, filtered/paginated by keyword opts."
  @callback list_approvals(session_id(), options()) :: result([approval()])

  @doc "Creates an artifact metadata row and, adapter permitting, its content reference."
  @callback create_artifact(artifact_attrs()) :: result(artifact())

  @doc "Fetches one artifact by id."
  @callback get_artifact(artifact_id()) :: result(artifact())

  @doc "Appends an event to the per-session durable timeline."
  @callback emit_event(event_attrs()) :: result(persisted_event())

  @doc "Lists events for one session in monotonic timeline order."
  @callback list_events(session_id(), options()) :: result([persisted_event()])

  @doc "Creates a durable workflow parent row. `start_step/1` requires this row to exist first."
  @callback create_workflow(workflow_attrs()) :: result(workflow())

  @doc "Updates a durable workflow's lifecycle status."
  @callback update_workflow_status(workflow_id(), workflow_status()) :: result(workflow())

  @doc "Fetches one durable workflow by id."
  @callback get_workflow(workflow_id()) :: result(workflow())

  @doc """
  Starts a durable workflow step, or returns the existing step for its
  idempotency key. The parent workflow MUST already exist via `create_workflow/1`.
  """
  @callback start_step(workflow_step_attrs()) ::
              {:ok, workflow_step()} | {:exists, workflow_step()} | {:error, error()}

  @doc "Commits a durable workflow step with output."
  @callback commit_step(workflow_step_id(), step_output()) :: result(workflow_step())

  @doc "Marks a durable workflow step as failed."
  @callback fail_step(workflow_step_id(), step_error()) :: result(workflow_step())

  @doc "Cancels a durable workflow step."
  @callback cancel_step(workflow_step_id()) :: result(workflow_step())

  @doc "Lists workflows pending recovery/resume."
  @callback list_pending_workflows() :: result([workflow()])

  @doc "Lists workflow steps for ordered replay."
  @callback list_steps(workflow_id()) :: result([workflow_step()])

  @doc "Claims a workflow for recovery/execution. Single-node adapters may always claim."
  @callback claim_workflow(workflow_id(), node(), pos_integer()) ::
              {:ok, :claimed} | {:error, :held_by, node()} | {:error, error()}

  # -- BD-0034: Event Log, Artifacts, Checkpoints, Workflow Steps, Error Log, Repair Queue --

  @doc "Appends an event to the session timeline and returns the persisted event."
  @callback append_event(event_attrs(), options()) :: result(persisted_event())

  @doc "Fetches a single event by its id."
  @callback get_event(id(), options()) :: result(persisted_event())

  @doc "Lists artifacts for a session, optionally filtered by task_id."
  @callback list_artifacts(session_id(), options()) :: result([artifact()])

  @doc "Saves a checkpoint for a session."
  @callback save_checkpoint(checkpoint_attrs(), options()) :: result(checkpoint())

  @doc "Fetches a checkpoint by id."
  @callback get_checkpoint(id(), options()) :: result(checkpoint())

  @doc "Lists checkpoints for a session."
  @callback list_checkpoints(session_id(), options()) :: result([checkpoint()])

  @doc "Deletes a checkpoint by id."
  @callback delete_checkpoint(id(), options()) :: result(:ok)

  @doc "Appends a workflow step to a session's step log."
  @callback append_step(workflow_step_attrs(), options()) :: result(workflow_step())

  @doc "Lists workflow steps for a session (aggregating across workflows)."
  @callback get_steps(session_id(), options()) :: result([workflow_step()])

  @doc "Logs an error entry to the error log."
  @callback log_error(error_log_attrs(), options()) :: result(error_log())

  @doc "Lists error log entries for a session."
  @callback list_errors(session_id(), options()) :: result([error_log()])

  @doc "Fetches a single error log entry by id."
  @callback get_error(id(), options()) :: result(error_log())

  @doc "Resolves an error log entry, setting status to :resolved."
  @callback resolve_error(id(), options()) :: result(error_log())

  @doc "Enqueues a repair entry for an error."
  @callback enqueue_repair(repair_attrs(), options()) :: result(repair())

  @doc "Dequeues the next pending repair entry."
  @callback dequeue_repair(options()) :: result(repair() | nil)

  @doc "Updates a repair entry (e.g., status transitions, result)."
  @callback update_repair(id(), repair_attrs(), options()) :: result(repair())

  @doc "Lists repair entries, optionally filtered by session or status."
  @callback list_repairs(options()) :: result([repair()])

  @doc "Deprecated compatibility alias for `append_message/1` used by scaffold runtime."
  @callback save_message(message(), options()) :: result(message())

  @doc "Compatibility transcript reader used by scaffold runtime."
  @callback list_messages(session_id(), options()) :: result([message()])

  @doc "Deprecated compatibility alias for `get_session/1` used by scaffold runtime."
  @callback fetch_session(session_id(), options()) :: result(session())

  @doc "Compatibility autosave writer retained until autosaves move out of the core store seam."
  @callback save_autosave(Tet.Autosave.t(), options()) :: result(Tet.Autosave.t())

  @doc "Compatibility autosave reader retained for scaffold runtime restore."
  @callback load_autosave(session_id(), options()) :: result(Tet.Autosave.t())

  @doc "Compatibility autosave listing retained for scaffold runtime."
  @callback list_autosaves(options()) :: result([Tet.Autosave.t()])

  @doc "Deprecated compatibility alias for `emit_event/1` used by scaffold runtime."
  @callback save_event(event(), options()) :: result(event())

  @doc "Compatibility Prompt Lab history writer retained for scaffold runtime."
  @callback save_prompt_history(Tet.PromptLab.HistoryEntry.t(), options()) ::
              result(Tet.PromptLab.HistoryEntry.t())

  @doc "Compatibility Prompt Lab history listing retained for scaffold runtime."
  @callback list_prompt_history(options()) :: result([Tet.PromptLab.HistoryEntry.t()])

  @doc "Compatibility Prompt Lab history reader retained for scaffold runtime."
  @callback fetch_prompt_history(id(), options()) :: result(Tet.PromptLab.HistoryEntry.t())

  @optional_callbacks boundary: 0,
                      health: 1,
                      list_sessions_with_opts: 1,
                      save_message: 2,
                      list_messages: 2,
                      fetch_session: 2,
                      save_event: 2,
                      save_autosave: 2,
                      load_autosave: 2,
                      list_autosaves: 1,
                      save_prompt_history: 2,
                      list_prompt_history: 1,
                      fetch_prompt_history: 2,
                      append_event: 2,
                      get_event: 2,
                      list_artifacts: 2,
                      save_checkpoint: 2,
                      get_checkpoint: 2,
                      list_checkpoints: 2,
                      delete_checkpoint: 2,
                      append_step: 2,
                      get_steps: 2,
                      log_error: 2,
                      list_errors: 2,
                      get_error: 2,
                      resolve_error: 2,
                      enqueue_repair: 2,
                      dequeue_repair: 1,
                      update_repair: 3,
                      list_repairs: 1
end
