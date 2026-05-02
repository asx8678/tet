defmodule Tet.Store.SQLite do
  @moduledoc """
  Default standalone store boundary backed by Ecto/SQLite3.

  Core callbacks (workspace, session, message, event, transaction) use
  `Tet.Store.SQLite.Repo` and Ecto schemas. Non-core callbacks (autosaves,
  prompt history, artifacts, checkpoints, errors, repairs, workflows,
  findings, persistent memories, project lessons) remain JSONL-backed
  until tet-3fp rewrites them.
  """

  @behaviour Tet.Store

  import Ecto.Query

  alias Tet.Store.SQLite.Jsonl
  alias Tet.Store.SQLite.Repo
  alias Tet.Store.SQLite.Schema

  # ── Boundary & Health ─────────────────────────────────────────────────

  @impl true
  def boundary do
    defaults = Jsonl.defaults()

    %{
      application: :tet_store_sqlite,
      adapter: __MODULE__,
      status: :local_jsonl,
      path: defaults.path,
      autosave_path: defaults.autosave_path,
      events_path: defaults.events_path,
      prompt_history_path: defaults.prompt_history_path,
      format: :jsonl
    }
  end

  @impl true
  def health(opts) when is_list(opts) do
    path = Jsonl.path(opts)
    directory = Path.dirname(path)
    directory_existed? = File.dir?(directory)

    result =
      with :ok <- File.mkdir_p(directory),
           :ok <- Jsonl.assert_readable(path),
           :ok <- Jsonl.assert_writable(directory) do
        {:ok,
         boundary()
         |> Map.merge(%{
           path: path,
           autosave_path: Jsonl.autosave_path(opts),
           events_path: Jsonl.events_path(opts),
           prompt_history_path: Jsonl.prompt_history_path(opts),
           directory: directory,
           status: :ok,
           readable?: true,
           writable?: true,
           started?: Jsonl.started?()
         })}
      else
        {:error, reason} -> {:error, {:store_unhealthy, path, reason}}
      end

    Jsonl.cleanup_created_directory(directory, directory_existed?)
    result
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

    {:ok, sessions}
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
    attrs =
      attrs
      |> ensure_id()
      |> ensure_created_at()

    with {:ok, event} <- Tet.Event.new(attrs) do
      insert_event_with_seq(event)
    end
  end

  @impl true
  def append_event(attrs, _opts) when is_map(attrs) do
    attrs =
      attrs
      |> ensure_id()
      |> ensure_created_at()

    with {:ok, event} <- Tet.Event.new(attrs) do
      insert_event_with_seq(event)
    end
  end

  @impl true
  def save_event(%Tet.Event{} = event, _opts) do
    insert_event_with_seq(event)
  end

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

  # ── Non-core stubs (still not implemented) ────────────────────────────

  @impl true
  def create_task(_attrs), do: {:error, {:not_implemented, :create_task}}

  @impl true
  def record_tool_run(_attrs), do: {:error, {:not_implemented, :record_tool_run}}

  @impl true
  def update_tool_run(_id, _attrs), do: {:error, {:not_implemented, :update_tool_run}}

  @impl true
  def create_approval(_attrs), do: {:error, {:not_implemented, :create_approval}}

  @impl true
  def resolve_approval(_id, _resolution, _attrs),
    do: {:error, {:not_implemented, :resolve_approval}}

  @impl true
  def get_approval(_id), do: {:error, {:not_implemented, :get_approval}}

  @impl true
  def list_approvals(_session_id, _opts), do: {:error, {:not_implemented, :list_approvals}}

  # ── Non-core JSONL callbacks ──────────────────────────────────────────

  @impl true
  def save_autosave(%Tet.Autosave{} = autosave, opts) when is_list(opts) do
    Jsonl.append_record(Jsonl.autosave_path(opts), autosave, &Tet.Autosave.to_map/1)
  end

  @impl true
  def load_autosave(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, autosaves} <- Jsonl.read_autosaves(Jsonl.autosave_path(opts)) do
      autosaves
      |> Enum.filter(&(&1.session_id == session_id))
      |> Enum.sort(&Jsonl.checkpoint_newer_or_equal?/2)
      |> case do
        [] -> {:error, :autosave_not_found}
        [latest | _] -> {:ok, latest}
      end
    end
  end

  @impl true
  def list_autosaves(opts) when is_list(opts) do
    with {:ok, autosaves} <- Jsonl.read_autosaves(Jsonl.autosave_path(opts)) do
      {:ok, Enum.sort(autosaves, &Jsonl.checkpoint_newer_or_equal?/2)}
    end
  end

  @impl true
  def save_prompt_history(%Tet.PromptLab.HistoryEntry{} = entry, opts) when is_list(opts) do
    Jsonl.append_record(
      Jsonl.prompt_history_path(opts),
      entry,
      &Tet.PromptLab.HistoryEntry.to_map/1
    )
  end

  @impl true
  def list_prompt_history(opts) when is_list(opts) do
    with {:ok, history} <- Jsonl.read_prompt_history(Jsonl.prompt_history_path(opts)) do
      {:ok, Enum.sort(history, &Jsonl.history_newer_or_equal?/2)}
    end
  end

  @impl true
  def fetch_prompt_history(id, opts) when is_binary(id) and is_list(opts) do
    Jsonl.find_by_id(
      Jsonl.prompt_history_path(opts),
      &Jsonl.read_prompt_history/1,
      id,
      :prompt_history_not_found
    )
  end

  # -- Artifacts --

  @impl true
  def create_artifact(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, artifact} <- Tet.ShellPolicy.Artifact.new(attrs) do
      Jsonl.append_record(
        Jsonl.artifacts_path(opts),
        artifact,
        &Tet.ShellPolicy.Artifact.to_map/1
      )
    end
  end

  @impl true
  def get_artifact(id, opts) when is_binary(id) and is_list(opts) do
    Jsonl.find_by_id(Jsonl.artifacts_path(opts), &Jsonl.read_artifacts/1, id, :artifact_not_found)
  end

  @impl true
  def list_artifacts(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, artifacts} <- Jsonl.read_artifacts(Jsonl.artifacts_path(opts)) do
      task_id = Keyword.get(opts, :task_id)

      filtered =
        Enum.filter(artifacts, fn a ->
          Jsonl.match_session?(a, session_id) and Jsonl.match_task?(a, task_id)
        end)

      {:ok, filtered}
    end
  end

  # -- Checkpoints --

  @impl true
  def save_checkpoint(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, cp} <- Tet.Checkpoint.new(attrs) do
      Jsonl.append_record(Jsonl.checkpoints_path(opts), cp, &Tet.Checkpoint.to_map/1)
    end
  end

  @impl true
  def get_checkpoint(id, opts) when is_binary(id) and is_list(opts) do
    Jsonl.find_by_id(
      Jsonl.checkpoints_path(opts),
      &Jsonl.read_checkpoints/1,
      id,
      :checkpoint_not_found
    )
  end

  @impl true
  def list_checkpoints(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, cps} <- Jsonl.read_checkpoints(Jsonl.checkpoints_path(opts)) do
      {:ok, Enum.filter(cps, &(&1.session_id == session_id))}
    end
  end

  @impl true
  def delete_checkpoint(id, opts) when is_binary(id) and is_list(opts) do
    path = Jsonl.checkpoints_path(opts)

    with {:ok, cps} <- Jsonl.read_checkpoints(path) do
      Jsonl.rewrite(path, Enum.reject(cps, &(&1.id == id)), &Tet.Checkpoint.to_map/1)
    end
  end

  # -- Workflow steps --

  @impl true
  def append_step(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, step} <- Tet.WorkflowStep.new(attrs) do
      Jsonl.append_record(Jsonl.workflow_steps_path(opts), step, &Tet.WorkflowStep.to_map/1)
    end
  end

  @impl true
  def get_steps(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, steps} <- Jsonl.read_workflow_steps(Jsonl.workflow_steps_path(opts)) do
      {:ok, Enum.filter(steps, &(&1.session_id == session_id))}
    end
  end

  # -- Error log --

  @impl true
  def log_error(attrs, opts) when is_map(attrs) and is_list(opts) do
    attrs = Tet.Store.Helpers.ensure_created_at(attrs)

    with {:ok, entry} <- Tet.ErrorLog.new(attrs) do
      Jsonl.append_record(Jsonl.error_log_path(opts), entry, &Tet.ErrorLog.to_map/1)
    end
  end

  @impl true
  def list_errors(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, errors} <- Jsonl.read_error_log(Jsonl.error_log_path(opts)) do
      {:ok, Enum.filter(errors, &(&1.session_id == session_id))}
    end
  end

  @impl true
  def get_error(id, opts) when is_binary(id) and is_list(opts) do
    Jsonl.find_by_id(Jsonl.error_log_path(opts), &Jsonl.read_error_log/1, id, :error_not_found)
  end

  @impl true
  def resolve_error(error_id, opts) when is_binary(error_id) and is_list(opts) do
    path = Jsonl.error_log_path(opts)

    with {:ok, errors} <- Jsonl.read_error_log(path) do
      case Enum.find(errors, &(&1.id == error_id)) do
        nil ->
          {:error, :error_not_found}

        entry ->
          resolved = Tet.ErrorLog.resolve(entry, DateTime.utc_now())
          remaining = Enum.reject(errors, &(&1.id == error_id)) ++ [resolved]

          case Jsonl.rewrite(path, remaining, &Tet.ErrorLog.to_map/1) do
            {:ok, :ok} -> {:ok, resolved}
            {:error, reason} -> {:error, {:resolve_error_write_failed, reason}}
          end
      end
    end
  end

  # -- Repair queue --

  @impl true
  def enqueue_repair(attrs, opts) when is_map(attrs) and is_list(opts) do
    attrs = Tet.Store.Helpers.ensure_created_at(attrs)

    with {:ok, repair} <- Tet.Repair.new(attrs) do
      Jsonl.append_record(Jsonl.repairs_path(opts), repair, &Tet.Repair.to_map/1)
    end
  end

  @impl true
  def dequeue_repair(opts) when is_list(opts) do
    path = Jsonl.repairs_path(opts)

    with {:ok, repairs} <- Jsonl.read_repairs(path) do
      repairs
      |> Enum.filter(&(&1.status == :pending))
      |> Enum.sort_by(& &1.created_at)
      |> case do
        [] ->
          {:ok, nil}

        [%Tet.Repair{} = repair | _] ->
          running = %{repair | status: :running, started_at: DateTime.utc_now()}
          remaining = Enum.reject(repairs, &(&1.id == repair.id)) ++ [running]

          with {:ok, :ok} <- Jsonl.rewrite(path, remaining, &Tet.Repair.to_map/1) do
            {:ok, running}
          end
      end
    end
  end

  @impl true
  def update_repair(repair_id, attrs, opts)
      when is_binary(repair_id) and is_map(attrs) and is_list(opts) do
    path = Jsonl.repairs_path(opts)

    with {:ok, repairs} <- Jsonl.read_repairs(path) do
      case Enum.find(repairs, &(&1.id == repair_id)) do
        nil ->
          {:error, :repair_not_found}

        repair ->
          case Tet.Store.Helpers.merge_repair_attrs(repair, attrs) do
            {:ok, updated} ->
              remaining = Enum.reject(repairs, &(&1.id == repair_id)) ++ [updated]

              with {:ok, :ok} <- Jsonl.rewrite(path, remaining, &Tet.Repair.to_map/1) do
                {:ok, updated}
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @impl true
  def list_repairs(opts) when is_list(opts) do
    with {:ok, repairs} <- Jsonl.read_repairs(Jsonl.repairs_path(opts)) do
      session_id = Keyword.get(opts, :session_id)
      status = Keyword.get(opts, :status)

      filtered =
        repairs
        |> Tet.Store.Helpers.maybe_filter_by_session(session_id)
        |> Tet.Store.Helpers.maybe_filter_by_status(status)

      {:ok, filtered}
    end
  end

  # -- Workflows --

  @impl true
  def create_workflow(attrs) when is_map(attrs) do
    with {:ok, workflow} <- Tet.Workflow.new(attrs), do: {:ok, workflow}
  end

  @impl true
  def update_workflow_status(_id, _status),
    do: {:error, {:not_implemented, :update_workflow_status}}

  @impl true
  def get_workflow(_id), do: {:error, {:not_implemented, :get_workflow}}

  @impl true
  def start_step(_attrs), do: {:error, {:not_implemented, :start_step}}

  @impl true
  def commit_step(_id, _output), do: {:error, {:not_implemented, :commit_step}}

  @impl true
  def fail_step(_id, _error), do: {:error, {:not_implemented, :fail_step}}

  @impl true
  def cancel_step(_id), do: {:error, {:not_implemented, :cancel_step}}

  @impl true
  def list_pending_workflows, do: {:ok, []}

  @impl true
  def list_steps(workflow_id) when is_binary(workflow_id), do: list_steps(workflow_id, [])

  @impl true
  def list_steps(workflow_id, opts) when is_binary(workflow_id) and is_list(opts) do
    with {:ok, steps} <- Jsonl.read_workflow_steps(Jsonl.workflow_steps_path(opts)) do
      {:ok, Enum.filter(steps, &(&1.workflow_id == workflow_id))}
    end
  end

  @impl true
  def claim_workflow(_id, _node, _ttl), do: {:ok, :claimed}

  # -- Findings --

  @impl true
  def record_finding(attrs, opts) when is_map(attrs) and is_list(opts) do
    attrs = Tet.Store.Helpers.ensure_created_at(attrs)

    with {:ok, finding} <- Tet.Finding.new(attrs) do
      Jsonl.append_record(Jsonl.findings_path(opts), finding, &Tet.Finding.to_map/1)
    end
  end

  @impl true
  def get_finding(id, opts) when is_binary(id) and is_list(opts) do
    Jsonl.find_by_id(Jsonl.findings_path(opts), &Jsonl.read_findings/1, id, :finding_not_found)
  end

  @impl true
  def list_findings(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, findings} <- Jsonl.read_findings(Jsonl.findings_path(opts)) do
      {:ok, Enum.filter(findings, &(&1.session_id == session_id))}
    end
  end

  @impl true
  def update_finding(finding_id, attrs, opts)
      when is_binary(finding_id) and is_map(attrs) and is_list(opts) do
    path = Jsonl.findings_path(opts)

    with {:ok, findings} <- Jsonl.read_findings(path) do
      case Enum.find(findings, &(&1.id == finding_id)) do
        nil ->
          {:error, :finding_not_found}

        finding ->
          case Tet.Store.Helpers.merge_finding_attrs(finding, attrs) do
            {:ok, updated} ->
              remaining = Enum.reject(findings, &(&1.id == finding_id)) ++ [updated]

              with {:ok, :ok} <- Jsonl.rewrite(path, remaining, &Tet.Finding.to_map/1) do
                {:ok, updated}
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  # -- Persistent memory --

  @impl true
  def store_persistent_memory(attrs, opts) when is_map(attrs) and is_list(opts) do
    attrs = Tet.Store.Helpers.ensure_created_at(attrs)

    with {:ok, entry} <- Tet.PersistentMemory.new(attrs) do
      Jsonl.append_record(
        Jsonl.persistent_memories_path(opts),
        entry,
        &Tet.PersistentMemory.to_map/1
      )
    end
  end

  @impl true
  def get_persistent_memory(id, opts) when is_binary(id) and is_list(opts) do
    Jsonl.find_by_id(
      Jsonl.persistent_memories_path(opts),
      &Jsonl.read_persistent_memories/1,
      id,
      :persistent_memory_not_found
    )
  end

  @impl true
  def list_persistent_memories(session_id, opts)
      when is_binary(session_id) and is_list(opts) do
    with {:ok, entries} <- Jsonl.read_persistent_memories(Jsonl.persistent_memories_path(opts)) do
      {:ok, Enum.filter(entries, &(&1.session_id == session_id))}
    end
  end

  # -- Project lessons --

  @impl true
  def store_project_lesson(attrs, opts) when is_map(attrs) and is_list(opts) do
    attrs = Tet.Store.Helpers.ensure_created_at(attrs)

    with {:ok, lesson} <- Tet.ProjectLesson.new(attrs) do
      Jsonl.append_record(
        Jsonl.project_lessons_path(opts),
        lesson,
        &Tet.ProjectLesson.to_map/1
      )
    end
  end

  @impl true
  def get_project_lesson(id, opts) when is_binary(id) and is_list(opts) do
    Jsonl.find_by_id(
      Jsonl.project_lessons_path(opts),
      &Jsonl.read_project_lessons/1,
      id,
      :project_lesson_not_found
    )
  end

  @impl true
  def list_project_lessons(opts) when is_list(opts) do
    with {:ok, lessons} <- Jsonl.read_project_lessons(Jsonl.project_lessons_path(opts)) do
      category = Keyword.get(opts, :category)
      {:ok, Tet.Store.Helpers.maybe_filter_lessons_by_category(lessons, category)}
    end
  end

  # ── Repo helpers (private) ────────────────────────────────────────────

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

  defp insert_message_with_seq(%Tet.Message{} = message) do
    Repo.transaction(fn ->
      sid = message.session_id

      max_seq =
        Repo.one(from m in Schema.Message, where: m.session_id == ^sid, select: max(m.seq)) || 0

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

      max_seq =
        Repo.one(from e in Schema.Event, where: e.session_id == ^sid, select: max(e.seq)) || 0

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

  defp prepare_session_update(attrs) do
    now_unix = DateTime.to_unix(DateTime.utc_now())

    attrs
    |> atomify_to_string([:mode, :status])
    |> maybe_encode_json(:metadata)
    |> coerce_timestamps([:started_at, :updated_at])
    |> Map.put(:updated_at, now_unix)
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
end
