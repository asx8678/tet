defmodule Tet.Store.SQLite do
  @moduledoc """
  Default standalone store boundary backed by Ecto/SQLite3.

  All callbacks use `Tet.Store.SQLite.Repo` and Ecto schemas.
  JSONL is dead. Long live Repo. 🐶
  """

  @behaviour Tet.Store

  import Ecto.Query

  alias Tet.Store.SQLite.Connection
  alias Tet.Store.SQLite.Repo
  alias Tet.Store.SQLite.Schema

  # ── Boundary & Health ─────────────────────────────────────────────────

  @impl true
  def boundary do
    %{
      application: :tet_store_sqlite,
      adapter: __MODULE__,
      status: :sqlite,
      database_path: Connection.default_database_path(),
      format: :sqlite
    }
  end

  @impl true
  def health(_opts) do
    try do
      snapshot = Connection.pragma_snapshot!()
      schema_version = query_schema_version()
      {:ok,
       boundary()
       |> Map.merge(%{
         status: :ok,
         journal_mode: snapshot.journal_mode,
         auto_vacuum: snapshot.auto_vacuum,
         schema_version: schema_version,
         started?: app_started?(),
         readable?: true,
         writable?: true
       })}
    rescue
      e -> {:error, {:store_unhealthy, Connection.default_database_path(), Exception.message(e)}}
    end
  end

  # ── Transaction ────────────────────────────────────────────────────────

  @impl true
  def transaction(fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
        value -> value
      end
    end)
  end

  # ── Workspace (Repo-backed) ───────────────────────────────────────────

  @impl true
  def create_workspace(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> ensure_id()
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)

    with {:ok, workspace} <- Tet.Workspace.new(attrs) do
      workspace
      |> Schema.Workspace.from_core_struct()
      |> Schema.Workspace.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.Workspace.to_core_struct/1)
    end
  end

  @impl true
  def get_workspace(id) when is_binary(id) do
    case Repo.get(Schema.Workspace, id) do
      nil -> {:error, :workspace_not_found}
      row -> {:ok, Schema.Workspace.to_core_struct(row)}
    end
  end

  @impl true
  def set_trust(id, trust_state) when is_binary(id) do
    case Repo.get(Schema.Workspace, id) do
      nil ->
        {:error, :workspace_not_found}

      row ->
        row
        |> Schema.Workspace.changeset(%{
          trust_state: to_string(trust_state),
          updated_at: DateTime.to_unix(DateTime.utc_now())
        })
        |> Repo.update()
        |> repo_result(&Schema.Workspace.to_core_struct/1)
    end
  end

  # ── Session (Repo-backed) ─────────────────────────────────────────────

  @impl true
  def create_session(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> ensure_id()
      |> ensure_short_id()
      |> Map.put_new(:created_at, DateTime.to_iso8601(now))
      |> Map.put_new(:updated_at, DateTime.to_iso8601(now))
      |> Map.put_new(:mode, :chat)
      |> Map.put_new(:status, :idle)

    with {:ok, session} <- Tet.Session.new(attrs) do
      session
      |> Schema.Session.from_core_struct()
      |> Schema.Session.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.Session.to_core_struct/1)
    end
  end

  @impl true
  def update_session(id, attrs) when is_binary(id) and is_map(attrs) do
    case Repo.get(Schema.Session, id) do
      nil ->
        {:error, :session_not_found}

      row ->
        row
        |> Schema.Session.changeset(prepare_session_update(attrs))
        |> Repo.update()
        |> repo_result(&Schema.Session.to_core_struct/1)
    end
  end

  @impl true
  def get_session(id) when is_binary(id) do
    case Repo.get(Schema.Session, id) do
      nil -> {:error, :session_not_found}
      row -> {:ok, Schema.Session.to_core_struct(row)}
    end
  end

  @impl true
  def list_sessions(opts) when is_list(opts) do
    sessions =
      Schema.Session
      |> order_by([s], desc: s.created_at)
      |> Repo.all()
      |> Enum.map(&Schema.Session.to_core_struct/1)
      |> Enum.map(&enrich_session_stats/1)

    {:ok, sessions}
  end

  @impl true
  def list_sessions(workspace_id) when is_binary(workspace_id) do
    sessions =
      Schema.Session
      |> where([s], s.workspace_id == ^workspace_id)
      |> order_by([s], desc: s.created_at)
      |> Repo.all()
      |> Enum.map(&Schema.Session.to_core_struct/1)
      |> Enum.map(&enrich_session_stats/1)

    {:ok, sessions}
  end

  defp enrich_session_stats(%Tet.Session{} = session) do
    sid = session.id

    stats =
      Repo.one(
        from m in Schema.Message,
          where: m.session_id == ^sid,
          select: %{count: count(m.id), last_role: max(m.role), last_content: fragment("?", m.content)}
      )

    # Get the last message content/role from the most recent message
    last_msg =
      Repo.one(
        from m in Schema.Message,
          where: m.session_id == ^sid,
          order_by: [desc: m.seq],
          limit: 1,
          select: %{role: m.role, content: m.content}
      )

    %{
      session
      | message_count: (stats[:count] || 0),
        last_role: last_msg && String.to_existing_atom(last_msg.role),
        last_content: last_msg && last_msg.content
    }
  end

  @impl true
  def list_sessions_with_opts(opts) when is_list(opts), do: list_sessions(opts)

  @impl true
  def fetch_session(session_id, _opts) when is_binary(session_id) do
    case Repo.get(Schema.Session, session_id) do
      nil -> {:error, :session_not_found}
      row -> {:ok, Schema.Session.to_core_struct(row)}
    end
  end

  # ── Message (Repo-backed) ─────────────────────────────────────────────

  @impl true
  def append_message(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> ensure_id()
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:timestamp, DateTime.to_iso8601(now))

    with {:ok, message} <- Tet.Message.new(attrs) do
      insert_message_with_seq(message)
    end
  end

  @impl true
  def save_message(%Tet.Message{} = message, _opts) do
    insert_message_with_seq(message)
  end

  @impl true
  def list_messages(session_id, _opts) when is_binary(session_id) do
    messages =
      Schema.Message
      |> where([m], m.session_id == ^session_id)
      |> order_by([m], asc: m.seq)
      |> Repo.all()
      |> Enum.map(&Schema.Message.to_core_struct/1)

    {:ok, messages}
  end

  # ── Event (Repo-backed) ───────────────────────────────────────────────

  @impl true
  def emit_event(attrs) when is_map(attrs) do
    attrs = attrs |> ensure_id() |> ensure_created_at()

    with {:ok, event} <- Tet.Event.new(attrs) do
      insert_event_with_seq(event)
    end
  end

  @impl true
  def append_event(attrs, _opts) when is_map(attrs) do
    attrs = attrs |> ensure_id() |> ensure_created_at()

    with {:ok, event} <- Tet.Event.new(attrs) do
      insert_event_with_seq(event)
    end
  end

  @impl true
  def save_event(%Tet.Event{} = event, _opts), do: insert_event_with_seq(event)

  @impl true
  def get_event(event_id, _opts) when is_binary(event_id) do
    case Repo.get(Schema.Event, event_id) do
      nil -> {:error, :event_not_found}
      row -> {:ok, Schema.Event.to_core_struct(row)}
    end
  end

  @impl true
  def list_events(session_id, _opts) when is_binary(session_id) do
    events =
      Schema.Event
      |> where([e], e.session_id == ^session_id)
      |> order_by([e], asc: e.seq)
      |> Repo.all()
      |> Enum.map(&Schema.Event.to_core_struct/1)

    {:ok, events}
  end

  def list_events(nil, _opts), do: {:ok, []}

  # ── Task ──────────────────────────────────────────────────────────────

  @impl true
  def create_task(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> ensure_id()
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)
      |> Map.put_new(:status, :active)

    with {:ok, task} <- Tet.Task.new(attrs) do
      task
      |> Schema.Task.from_core_struct()
      |> Schema.Task.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.Task.to_core_struct/1)
    end
  end

  # ── Tool Runs ─────────────────────────────────────────────────────────

  @impl true
  def record_tool_run(attrs) when is_map(attrs) do
    attrs = attrs |> ensure_id()

    with {:ok, tool_run} <- Tet.ToolRun.new(attrs) do
      tool_run
      |> Schema.ToolRun.from_core_struct()
      |> Schema.ToolRun.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.ToolRun.to_core_struct/1)
    end
  end

  @impl true
  def update_tool_run(id, attrs) when is_binary(id) and is_map(attrs) do
    case Repo.get(Schema.ToolRun, id) do
      nil ->
        {:error, :tool_run_not_found}

      row ->
        row
        |> Schema.ToolRun.changeset(prepare_tool_run_update(attrs))
        |> Repo.update()
        |> repo_result(&Schema.ToolRun.to_core_struct/1)
    end
  end

  # ── Approvals ─────────────────────────────────────────────────────────

  @impl true
  def create_approval(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> ensure_id()
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:status, :pending)

    with {:ok, approval} <- Tet.Approval.Approval.new(attrs) do
      approval
      |> Schema.Approval.from_core_struct()
      |> Schema.Approval.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.Approval.to_core_struct/1)
    end
  end

  @impl true
  def resolve_approval(id, resolution, attrs)
      when is_binary(id) and is_atom(resolution) and is_map(attrs) do
    now = DateTime.utc_now()

    case Repo.get(Schema.Approval, id) do
      nil ->
        {:error, :approval_not_found}

      row ->
        row
        |> Schema.Approval.changeset(%{
          status: Atom.to_string(resolution),
          reason: Map.get(attrs, :reason, Map.get(attrs, :rationale, "")),
          resolved_at: DateTime.to_unix(now),
          updated_at: DateTime.to_unix(now)
        })
        |> Repo.update()
        |> repo_result(&Schema.Approval.to_core_struct/1)
    end
  end

  @impl true
  def get_approval(id) when is_binary(id) do
    case Repo.get(Schema.Approval, id) do
      nil -> {:error, :approval_not_found}
      row -> {:ok, Schema.Approval.to_core_struct(row)}
    end
  end

  @impl true
  def list_approvals(session_id, _opts) when is_binary(session_id) do
    approvals =
      Schema.Approval
      |> where([a], a.session_id == ^session_id)
      |> order_by([a], desc: a.created_at)
      |> Repo.all()
      |> Enum.map(&Schema.Approval.to_core_struct/1)

    {:ok, approvals}
  end

  # ── Autosaves ─────────────────────────────────────────────────────────

  @impl true
  def save_autosave(%Tet.Autosave{} = autosave, _opts) do
    autosave
    |> Schema.Autosave.from_core_struct()
    |> Schema.Autosave.changeset()
    |> Repo.insert()
    |> repo_result(&Schema.Autosave.to_core_struct/1)
  end

  @impl true
  def load_autosave(session_id, _opts) when is_binary(session_id) do
    case Schema.Autosave
         |> where([a], a.session_id == ^session_id)
         |> order_by([a], desc: a.saved_at)
         |> limit(1)
         |> Repo.one() do
      nil -> {:error, :autosave_not_found}
      row -> {:ok, Schema.Autosave.to_core_struct(row)}
    end
  end

  @impl true
  def list_autosaves(_opts) do
    autosaves =
      Schema.Autosave
      |> order_by([a], desc: a.saved_at)
      |> Repo.all()
      |> Enum.map(&Schema.Autosave.to_core_struct/1)

    {:ok, autosaves}
  end

  # ── Prompt History ────────────────────────────────────────────────────

  @impl true
  def save_prompt_history(%Tet.PromptLab.HistoryEntry{} = entry, _opts) do
    entry
    |> Schema.PromptHistoryEntry.from_core_struct()
    |> Schema.PromptHistoryEntry.changeset()
    |> Repo.insert()
    |> repo_result(&Schema.PromptHistoryEntry.to_core_struct/1)
  end

  @impl true
  def list_prompt_history(_opts) do
    entries =
      Schema.PromptHistoryEntry
      |> order_by([e], desc: e.created_at)
      |> Repo.all()
      |> Enum.map(&Schema.PromptHistoryEntry.to_core_struct/1)

    {:ok, entries}
  end

  @impl true
  def fetch_prompt_history(id, _opts) when is_binary(id) do
    case Repo.get(Schema.PromptHistoryEntry, id) do
      nil -> {:error, :prompt_history_not_found}
      row -> {:ok, Schema.PromptHistoryEntry.to_core_struct(row)}
    end
  end

  # ── Artifacts ─────────────────────────────────────────────────────────

  @impl true
  def create_artifact(attrs, _opts) when is_map(attrs) do
    attrs = attrs |> ensure_id() |> ensure_created_at()

    attrs
    |> Schema.Artifact.changeset()
    |> Repo.insert()
    |> repo_result(&Schema.Artifact.to_core_struct/1)
  end

  @impl true
  def get_artifact(id, _opts) when is_binary(id) do
    case Repo.get(Schema.Artifact, id) do
      nil -> {:error, :artifact_not_found}
      row -> {:ok, Schema.Artifact.to_core_struct(row)}
    end
  end

  @impl true
  def list_artifacts(session_id, opts) when is_binary(session_id) and is_list(opts) do
    task_id = Keyword.get(opts, :task_id)

    query =
      Schema.Artifact
      |> where([a], a.session_id == ^session_id)
      |> then(fn q ->
        if task_id,
          do: where(q, [a], fragment("json_extract(metadata, '$.task_id') = ?", ^task_id)),
          else: q
      end)
      |> order_by([a], desc: a.created_at)

    {:ok, query |> Repo.all() |> Enum.map(&Schema.Artifact.to_core_struct/1)}
  end

  # ── Checkpoints ───────────────────────────────────────────────────────

  @impl true
  def save_checkpoint(attrs, _opts) when is_map(attrs) do
    with {:ok, cp} <- Tet.Checkpoint.new(attrs) do
      cp
      |> Schema.Checkpoint.from_core_struct()
      |> Schema.Checkpoint.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.Checkpoint.to_core_struct/1)
    end
  end

  @impl true
  def get_checkpoint(id, _opts) when is_binary(id) do
    case Repo.get(Schema.Checkpoint, id) do
      nil -> {:error, :checkpoint_not_found}
      row -> {:ok, Schema.Checkpoint.to_core_struct(row)}
    end
  end

  @impl true
  def list_checkpoints(session_id, _opts) when is_binary(session_id) do
    checkpoints =
      Schema.Checkpoint
      |> where([c], c.session_id == ^session_id)
      |> order_by([c], desc: c.created_at)
      |> Repo.all()
      |> Enum.map(&Schema.Checkpoint.to_core_struct/1)

    {:ok, checkpoints}
  end

  @impl true
  def delete_checkpoint(id, _opts) when is_binary(id) do
    case Repo.get(Schema.Checkpoint, id) do
      nil ->
        {:error, :checkpoint_not_found}

      row ->
        Repo.delete(row)
        |> then(fn
          {:ok, _} -> {:ok, :ok}
          err -> err
        end)
    end
  end

  # ── Workflows ─────────────────────────────────────────────────────────

  @impl true
  def create_workflow(attrs) when is_map(attrs) do
    now = DateTime.utc_now()

    attrs =
      attrs
      |> ensure_id()
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)
      |> Map.put_new(:status, :running)

    with {:ok, workflow} <- Tet.Workflow.new(attrs) do
      workflow
      |> Schema.Workflow.from_core_struct()
      |> Schema.Workflow.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.Workflow.to_core_struct/1)
    end
  end

  @impl true
  def update_workflow_status(id, status) when is_binary(id) do
    case Repo.get(Schema.Workflow, id) do
      nil ->
        {:error, :workflow_not_found}

      row ->
        now = DateTime.to_unix(DateTime.utc_now())

        row
        |> Schema.Workflow.changeset(%{status: to_string(status), updated_at: now})
        |> Repo.update()
        |> repo_result(&Schema.Workflow.to_core_struct/1)
    end
  end

  @impl true
  def get_workflow(id) when is_binary(id) do
    case Repo.get(Schema.Workflow, id) do
      nil -> {:error, :workflow_not_found}
      row -> {:ok, Schema.Workflow.to_core_struct(row)}
    end
  end

  @impl true
  def list_pending_workflows do
    workflows =
      Schema.Workflow
      |> where([w], w.status in ["running", "paused_for_approval"])
      |> order_by([w], asc: w.updated_at)
      |> Repo.all()
      |> Enum.map(&Schema.Workflow.to_core_struct/1)

    {:ok, workflows}
  end

  @impl true
  def claim_workflow(id, node, ttl) when is_binary(id) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl, :millisecond) |> DateTime.to_unix()

    case Repo.get(Schema.Workflow, id) do
      nil ->
        {:error, :workflow_not_found}

      row ->
        row
        |> Schema.Workflow.changeset(%{
          claimed_by: to_string(node),
          claim_expires_at: expires_at,
          updated_at: DateTime.to_unix(now)
        })
        |> Repo.update()
        |> case do
          {:ok, _} -> {:ok, :claimed}
          {:error, cs} -> {:error, {:changeset_error, cs}}
        end
    end
  end

  # ── Workflow Steps ────────────────────────────────────────────────────

  @impl true
  def start_step(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> ensure_id()
      |> Map.put_new(:status, :started)
      |> Map.put_new(:started_at, DateTime.utc_now())

    idem_key = Map.get(attrs, :idempotency_key)
    workflow_id = Map.get(attrs, :workflow_id)

    if idem_key && workflow_id do
      case Repo.one(
             from(s in Schema.WorkflowStep,
               where: s.workflow_id == ^workflow_id and s.idempotency_key == ^idem_key
             )
           ) do
        nil -> insert_workflow_step(attrs)
        existing -> {:ok, Schema.WorkflowStep.to_core_struct(existing)}
      end
    else
      insert_workflow_step(attrs)
    end
  end

  @impl true
  def commit_step(id, output) when is_binary(id) do
    update_step(id, %{
      output: Schema.JsonField.encode(output),
      status: "committed",
      committed_at: DateTime.to_unix(DateTime.utc_now())
    })
  end

  @impl true
  def fail_step(id, error) when is_binary(id) do
    update_step(id, %{
      error: Schema.JsonField.encode(error),
      status: "failed",
      failed_at: DateTime.to_unix(DateTime.utc_now())
    })
  end

  @impl true
  def cancel_step(id) when is_binary(id) do
    update_step(id, %{
      status: "cancelled",
      cancelled_at: DateTime.to_unix(DateTime.utc_now())
    })
  end

  @impl true
  def list_steps(workflow_id) when is_binary(workflow_id), do: list_steps(workflow_id, [])

  @impl true
  def list_steps(workflow_id, _opts) when is_binary(workflow_id) do
    steps =
      Schema.WorkflowStep
      |> where([s], s.workflow_id == ^workflow_id)
      |> order_by([s], asc: s.started_at)
      |> Repo.all()
      |> Enum.map(&Schema.WorkflowStep.to_core_struct/1)

    {:ok, steps}
  end

  @impl true
  def append_step(attrs, _opts) when is_map(attrs) do
    attrs =
      attrs
      |> ensure_id()
      |> Map.put_new(:status, :started)
      |> Map.put_new(:started_at, DateTime.utc_now())

    insert_workflow_step(attrs)
  end

  @impl true
  def get_steps(session_id, _opts) when is_binary(session_id) do
    # Workflow steps don't have session_id directly — join through workflows.
    steps =
      from(s in Schema.WorkflowStep,
        join: w in Schema.Workflow,
        on: s.workflow_id == w.id,
        where: w.session_id == ^session_id,
        order_by: [asc: s.started_at]
      )
      |> Repo.all()
      |> Enum.map(&Schema.WorkflowStep.to_core_struct/1)

    {:ok, steps}
  end

  # ── Error Log ─────────────────────────────────────────────────────────

  @impl true
  def log_error(attrs, _opts) when is_map(attrs) do
    attrs = attrs |> ensure_id() |> Tet.Store.Helpers.ensure_created_at()

    with {:ok, entry} <- Tet.ErrorLog.new(attrs) do
      entry
      |> Schema.ErrorLogEntry.from_core_struct()
      |> Schema.ErrorLogEntry.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.ErrorLogEntry.to_core_struct/1)
    end
  end

  @impl true
  def list_errors(session_id, _opts) when is_binary(session_id) do
    errors =
      Schema.ErrorLogEntry
      |> where([e], e.session_id == ^session_id)
      |> order_by([e], desc: e.created_at)
      |> Repo.all()
      |> Enum.map(&Schema.ErrorLogEntry.to_core_struct/1)

    {:ok, errors}
  end

  @impl true
  def get_error(id, _opts) when is_binary(id) do
    case Repo.get(Schema.ErrorLogEntry, id) do
      nil -> {:error, :error_not_found}
      row -> {:ok, Schema.ErrorLogEntry.to_core_struct(row)}
    end
  end

  @impl true
  def resolve_error(error_id, _opts) when is_binary(error_id) do
    now = DateTime.utc_now()

    case Repo.get(Schema.ErrorLogEntry, error_id) do
      nil ->
        {:error, :error_not_found}

      row ->
        row
        |> Schema.ErrorLogEntry.changeset(%{
          status: "resolved",
          resolved_at: DateTime.to_unix(now)
        })
        |> Repo.update()
        |> repo_result(&Schema.ErrorLogEntry.to_core_struct/1)
    end
  end

  # ── Repair Queue ──────────────────────────────────────────────────────

  @impl true
  def enqueue_repair(attrs, _opts) when is_map(attrs) do
    attrs = attrs |> ensure_id() |> Tet.Store.Helpers.ensure_created_at()

    with {:ok, repair} <- Tet.Repair.new(attrs) do
      repair
      |> Schema.Repair.from_core_struct()
      |> Schema.Repair.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.Repair.to_core_struct/1)
    end
  end

  @impl true
  def dequeue_repair(_opts) do
    # Atomic: select oldest pending + update to running in one transaction.
    Repo.transaction(fn ->
      case Repo.one(
             from(r in Schema.Repair,
               where: r.status == "pending",
               order_by: [asc: r.created_at],
               limit: 1,
               lock: "FOR UPDATE"
             )
           ) do
        nil ->
          nil

        row ->
          now = DateTime.to_unix(DateTime.utc_now())

          case row
               |> Schema.Repair.changeset(%{status: "running", started_at: now})
               |> Repo.update() do
            {:ok, updated} -> Schema.Repair.to_core_struct(updated)
            {:error, cs} -> Repo.rollback({:changeset_error, cs})
          end
      end
    end)
    |> case do
      {:ok, nil} -> {:ok, nil}
      {:ok, repair} -> {:ok, repair}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def update_repair(repair_id, attrs, _opts)
      when is_binary(repair_id) and is_map(attrs) do
    case Repo.get(Schema.Repair, repair_id) do
      nil ->
        {:error, :repair_not_found}

      row ->
        core = Schema.Repair.to_core_struct(row)

        with {:ok, updated} <- Tet.Store.Helpers.merge_repair_attrs(core, attrs) do
          changeset_attrs = Schema.Repair.from_core_struct(updated)

          row
          |> Schema.Repair.changeset(changeset_attrs)
          |> Repo.update()
          |> repo_result(&Schema.Repair.to_core_struct/1)
        end
    end
  end

  @impl true
  def list_repairs(opts) when is_list(opts) do
    session_id = Keyword.get(opts, :session_id)
    status = Keyword.get(opts, :status)

    repairs =
      Schema.Repair
      |> then(fn q ->
        if session_id, do: where(q, [r], r.session_id == ^session_id), else: q
      end)
      |> then(fn q ->
        if status, do: where(q, [r], r.status == ^to_string(status)), else: q
      end)
      |> order_by([r], asc: r.created_at)
      |> Repo.all()
      |> Enum.map(&Schema.Repair.to_core_struct/1)

    {:ok, repairs}
  end

  # ── Findings ──────────────────────────────────────────────────────────

  @impl true
  def record_finding(attrs, _opts) when is_map(attrs) do
    attrs = attrs |> ensure_id() |> Tet.Store.Helpers.ensure_created_at()

    with {:ok, finding} <- Tet.Finding.new(attrs) do
      finding
      |> Schema.Finding.from_core_struct()
      |> Schema.Finding.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.Finding.to_core_struct/1)
    end
  end

  @impl true
  def get_finding(id, _opts) when is_binary(id) do
    case Repo.get(Schema.Finding, id) do
      nil -> {:error, :finding_not_found}
      row -> {:ok, Schema.Finding.to_core_struct(row)}
    end
  end

  @impl true
  def list_findings(session_id, _opts) when is_binary(session_id) do
    findings =
      Schema.Finding
      |> where([f], f.session_id == ^session_id)
      |> order_by([f], desc: f.created_at)
      |> Repo.all()
      |> Enum.map(&Schema.Finding.to_core_struct/1)

    {:ok, findings}
  end

  @impl true
  def update_finding(finding_id, attrs, _opts)
      when is_binary(finding_id) and is_map(attrs) do
    case Repo.get(Schema.Finding, finding_id) do
      nil ->
        {:error, :finding_not_found}

      row ->
        core = Schema.Finding.to_core_struct(row)

        with {:ok, updated} <- Tet.Store.Helpers.merge_finding_attrs(core, attrs) do
          changeset_attrs = Schema.Finding.from_core_struct(updated)

          row
          |> Schema.Finding.changeset(changeset_attrs)
          |> Repo.update()
          |> repo_result(&Schema.Finding.to_core_struct/1)
        end
    end
  end

  # ── Persistent Memory ────────────────────────────────────────────────

  @impl true
  def store_persistent_memory(attrs, _opts) when is_map(attrs) do
    attrs = attrs |> ensure_id() |> Tet.Store.Helpers.ensure_created_at()

    with {:ok, entry} <- Tet.PersistentMemory.new(attrs) do
      entry
      |> Schema.PersistentMemory.from_core_struct()
      |> Schema.PersistentMemory.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.PersistentMemory.to_core_struct/1)
    end
  end

  @impl true
  def get_persistent_memory(id, _opts) when is_binary(id) do
    case Repo.get(Schema.PersistentMemory, id) do
      nil -> {:error, :persistent_memory_not_found}
      row -> {:ok, Schema.PersistentMemory.to_core_struct(row)}
    end
  end

  @impl true
  def list_persistent_memories(session_id, _opts) when is_binary(session_id) do
    entries =
      Schema.PersistentMemory
      |> where([pm], pm.session_id == ^session_id)
      |> order_by([pm], desc: pm.created_at)
      |> Repo.all()
      |> Enum.map(&Schema.PersistentMemory.to_core_struct/1)

    {:ok, entries}
  end

  # ── Project Lessons ───────────────────────────────────────────────────

  @impl true
  def store_project_lesson(attrs, _opts) when is_map(attrs) do
    attrs = attrs |> ensure_id() |> Tet.Store.Helpers.ensure_created_at()

    with {:ok, lesson} <- Tet.ProjectLesson.new(attrs) do
      lesson
      |> Schema.ProjectLesson.from_core_struct()
      |> Schema.ProjectLesson.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.ProjectLesson.to_core_struct/1)
    end
  end

  @impl true
  def get_project_lesson(id, _opts) when is_binary(id) do
    case Repo.get(Schema.ProjectLesson, id) do
      nil -> {:error, :project_lesson_not_found}
      row -> {:ok, Schema.ProjectLesson.to_core_struct(row)}
    end
  end

  @impl true
  def list_project_lessons(opts) when is_list(opts) do
    category = Keyword.get(opts, :category)

    lessons =
      Schema.ProjectLesson
      |> then(fn q ->
        if category, do: where(q, [pl], pl.category == ^to_string(category)), else: q
      end)
      |> order_by([pl], desc: pl.created_at)
      |> Repo.all()
      |> Enum.map(&Schema.ProjectLesson.to_core_struct/1)

    {:ok, lessons}
  end

  # ── Private helpers ───────────────────────────────────────────────────

  defp ensure_id(attrs) do
    case Tet.Entity.fetch_value(attrs, :id) do
      v when is_binary(v) and v != "" -> attrs
      _ -> Map.put(attrs, :id, generate_id())
    end
  end

  defp ensure_short_id(attrs) do
    case Tet.Entity.fetch_value(attrs, :short_id) do
      v when is_binary(v) and v != "" ->
        attrs

      _ ->
        id = Tet.Entity.fetch_value(attrs, :id) || ""
        Map.put(attrs, :short_id, String.slice(id, 0, 8))
    end
  end

  defp ensure_created_at(attrs) do
    case Tet.Entity.fetch_value(attrs, :created_at) do
      nil -> Map.put(attrs, :created_at, DateTime.utc_now())
      "" -> Map.put(attrs, :created_at, DateTime.utc_now())
      _ -> attrs
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp repo_result({:ok, row}, to_core), do: {:ok, to_core.(row)}
  defp repo_result({:error, %Ecto.Changeset{} = cs}, _), do: {:error, {:changeset_error, cs}}
  defp repo_result({:error, reason}, _), do: {:error, reason}

  # Auto-ensures a session row exists so that message/event FK constraints are
  # satisfied. Also ensures the parent workspace row exists. Idempotent.
  defp ensure_session_exists!(session_id) do
    case Repo.get(Schema.Session, session_id) do
      nil ->
        ensure_workspace_exists!("ws_default")
        now = DateTime.to_unix(DateTime.utc_now())

        attrs = %{
          id: session_id,
          workspace_id: "ws_default",
          short_id: String.slice(session_id, 0, 8),
          mode: "chat",
          status: "idle",
          created_at: now,
          updated_at: now
        }

        case Schema.Session.changeset(attrs) |> Repo.insert() do
          {:ok, _row} -> :ok
          {:error, %Ecto.Changeset{errors: [{:id, {_, [constraint: :unique]}} | _]}} -> :ok
          {:error, _cs} -> :ok
        end

      _row ->
        :ok
    end
  end

  defp ensure_workspace_exists!(workspace_id) do
    case Repo.get(Schema.Workspace, workspace_id) do
      nil ->
        now = DateTime.to_unix(DateTime.utc_now())

        attrs = %{
          id: workspace_id,
          name: "default",
          root_path: "/",
          tet_dir_path: ".tet",
          trust_state: "trusted",
          created_at: now,
          updated_at: now
        }

        case Schema.Workspace.changeset(attrs) |> Repo.insert() do
          {:ok, _row} -> :ok
          {:error, %Ecto.Changeset{errors: [{:id, {_, [constraint: :unique]}} | _]}} -> :ok
          {:error, _cs} -> :ok
        end

      _row ->
        :ok
    end
  end

  defp insert_message_with_seq(%Tet.Message{} = message) do
    Repo.transaction(fn ->
      sid = message.session_id
      ensure_session_exists!(sid)

      max_seq =
        Repo.one(from(m in Schema.Message, where: m.session_id == ^sid, select: max(m.seq))) || 0

      new_seq = max_seq + 1

      db_attrs =
        message
        |> Schema.Message.from_core_struct(seq: new_seq)
        |> default_unix_timestamp(:created_at)

      case Schema.Message.changeset(db_attrs) |> Repo.insert() do
        {:ok, row} -> Schema.Message.to_core_struct(row)
        {:error, cs} -> Repo.rollback({:changeset_error, cs})
      end
    end)
  end

  defp insert_event_with_seq(%Tet.Event{} = event) do
    event = fill_event_defaults(event)

    Repo.transaction(fn ->
      sid = event.session_id
      if is_binary(sid) and sid != "", do: ensure_session_exists!(sid)

      max_seq =
        Repo.one(from(e in Schema.Event, where: e.session_id == ^sid, select: max(e.seq))) || 0

      new_seq = max_seq + 1
      event = %{event | seq: new_seq, sequence: new_seq}

      db_attrs =
        event
        |> Schema.Event.from_core_struct()
        |> default_unix_timestamp(:inserted_at)

      case Schema.Event.changeset(db_attrs) |> Repo.insert() do
        {:ok, row} -> Schema.Event.to_core_struct(row)
        {:error, cs} -> Repo.rollback({:changeset_error, cs})
      end
    end)
  end

  defp fill_event_defaults(%Tet.Event{} = event) do
    event
    |> then(fn
      %{id: id} = e when id in [nil, ""] -> %{e | id: generate_id()}
      e -> e
    end)
    |> then(fn
      %{created_at: nil} = e -> %{e | created_at: DateTime.utc_now()}
      e -> e
    end)
  end

  defp insert_workflow_step(attrs) do
    with {:ok, step} <- Tet.WorkflowStep.new(attrs) do
      step
      |> Schema.WorkflowStep.from_core_struct()
      |> Schema.WorkflowStep.changeset()
      |> Repo.insert()
      |> repo_result(&Schema.WorkflowStep.to_core_struct/1)
    end
  end

  defp update_step(id, update_attrs) do
    case Repo.get(Schema.WorkflowStep, id) do
      nil ->
        {:error, :step_not_found}

      row ->
        row
        |> Schema.WorkflowStep.changeset(update_attrs)
        |> Repo.update()
        |> repo_result(&Schema.WorkflowStep.to_core_struct/1)
    end
  end

  defp prepare_session_update(attrs) do
    now_unix = DateTime.to_unix(DateTime.utc_now())

    attrs
    |> atomify_to_string([:mode, :status])
    |> maybe_encode_json(:metadata)
    |> coerce_timestamps([:started_at, :updated_at])
    |> Map.put(:updated_at, now_unix)
  end

  defp prepare_tool_run_update(attrs) do
    attrs
    |> atomify_to_string([:status, :read_or_write, :block_reason])
    |> maybe_encode_json(:args)
    |> maybe_encode_json(:result)
    |> maybe_encode_json(:changed_files)
    |> maybe_encode_json(:metadata)
    |> coerce_timestamps([:started_at, :finished_at])
  end

  defp atomify_to_string(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      case Map.get(acc, key) do
        v when is_atom(v) and not is_nil(v) -> Map.put(acc, key, to_string(v))
        _ -> acc
      end
    end)
  end

  defp maybe_encode_json(attrs, key) do
    case Map.get(attrs, key) do
      v when is_map(v) -> Map.put(attrs, key, Schema.JsonField.encode(v))
      v when is_list(v) -> Map.put(attrs, key, Schema.JsonField.encode(v))
      _ -> attrs
    end
  end

  defp coerce_timestamps(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      case Map.get(acc, key) do
        %DateTime{} = dt ->
          Map.put(acc, key, DateTime.to_unix(dt))

        iso when is_binary(iso) ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _} -> Map.put(acc, key, DateTime.to_unix(dt))
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp default_unix_timestamp(%{} = attrs, key) do
    case Map.get(attrs, key) do
      nil -> Map.put(attrs, key, DateTime.to_unix(DateTime.utc_now()))
      _ -> attrs
    end
  end

  defp query_schema_version do
    case Ecto.Adapters.SQL.query(Repo, "PRAGMA schema_version;", [], log: false) do
      {:ok, %{rows: [[v]]}} -> v
      _ -> nil
    end
  end

  defp app_started? do
    Enum.any?(Application.started_applications(), fn {app, _, _} ->
      app == :tet_store_sqlite
    end)
  end
end
