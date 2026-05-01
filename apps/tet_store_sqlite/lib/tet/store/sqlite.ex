defmodule Tet.Store.SQLite do
  @moduledoc """
  Default standalone store boundary.

  This phase keeps the adapter dependency-free and persists chat messages,
  autosave checkpoints, runtime timeline events, Prompt Lab history entries,
  artifacts, checkpoints, error log entries, and repair queue entries
  as JSON Lines. The app/module name remains the default store boundary
  reserved by the scaffold; a later storage ticket can replace the file format
  with true SQLite without changing callers of `Tet.Store`.
  """

  @behaviour Tet.Store

  @default_path ".tet/messages.jsonl"
  @default_autosave_filename "autosaves.jsonl"
  @default_prompt_history_filename "prompt_history.jsonl"
  @default_events_path ".tet/events.jsonl"
  @default_artifacts_path ".tet/artifacts.jsonl"
  @default_checkpoints_path ".tet/checkpoints.jsonl"
  @default_error_log_path ".tet/error_log.jsonl"
  @default_repairs_path ".tet/repairs.jsonl"

  @impl true
  def boundary do
    %{
      application: :tet_store_sqlite,
      adapter: __MODULE__,
      status: :local_jsonl,
      path: @default_path,
      autosave_path: default_autosave_path(@default_path),
      events_path: derive_events_path(@default_path),
      prompt_history_path: default_prompt_history_path(@default_path),
      format: :jsonl
    }
  end

  @impl true
  def health(opts) when is_list(opts) do
    path = path(opts)
    autosave_path = autosave_path(opts)
    events_path = events_path(opts)
    prompt_history_path = prompt_history_path(opts)
    directory = Path.dirname(path)
    directory_existed? = File.dir?(directory)

    result =
      with :ok <- File.mkdir_p(directory),
           :ok <- assert_readable(path),
           :ok <- assert_writable(directory) do
        {:ok,
         boundary()
         |> Map.merge(%{
           path: path,
           autosave_path: autosave_path,
           events_path: events_path,
           prompt_history_path: prompt_history_path,
           directory: directory,
           status: :ok,
           readable?: true,
           writable?: true,
           started?: started?()
         })}
      else
        {:error, reason} -> {:error, {:store_unhealthy, path, reason}}
      end

    cleanup_created_directory(directory, directory_existed?)
    result
  end

  # -- Compatibility callbacks (scaffold-era) --

  @impl true
  def save_message(%Tet.Message{} = message, opts) when is_list(opts) do
    path = path(opts)
    line = message |> Tet.Message.to_map() |> encode_json!()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, message}
    end
  end

  @impl true
  def list_messages(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, messages} <- read_messages(path(opts)) do
      {:ok, Enum.filter(messages, &(&1.session_id == session_id))}
    end
  end

  @impl true
  def list_sessions(opts) when is_list(opts) do
    with {:ok, messages} <- read_messages(path(opts)) do
      sessions =
        messages
        |> Enum.group_by(& &1.session_id)
        |> Enum.map(fn {session_id, session_messages} ->
          {:ok, session} = Tet.Session.from_messages(session_id, session_messages)
          session
        end)
        |> Enum.sort(&session_newer_or_equal?/2)

      {:ok, sessions}
    end
  end

  @impl true
  def list_sessions(workspace_id) when is_binary(workspace_id) do
    _workspace_id = workspace_id
    {:error, {:not_implemented, :list_sessions}}
  end

  @impl true
  def fetch_session(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, messages} <- list_messages(session_id, opts) do
      Tet.Session.from_messages(session_id, messages)
    end
  end

  @impl true
  def save_autosave(%Tet.Autosave{} = autosave, opts) when is_list(opts) do
    path = autosave_path(opts)
    line = autosave |> Tet.Autosave.to_map() |> encode_json!()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, autosave}
    end
  end

  @impl true
  def load_autosave(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, autosaves} <- read_autosaves(autosave_path(opts)) do
      autosaves
      |> Enum.filter(&(&1.session_id == session_id))
      |> Enum.sort(&checkpoint_newer_or_equal?/2)
      |> case do
        [] -> {:error, :autosave_not_found}
        [latest | _rest] -> {:ok, latest}
      end
    end
  end

  @impl true
  def list_autosaves(opts) when is_list(opts) do
    with {:ok, autosaves} <- read_autosaves(autosave_path(opts)) do
      {:ok, Enum.sort(autosaves, &checkpoint_newer_or_equal?/2)}
    end
  end

  @impl true
  def save_event(%Tet.Event{} = event, opts) when is_list(opts) do
    path = events_path(opts)

    with {:ok, event} <- assign_event_sequence(event, path),
         line = event |> Tet.Event.to_map() |> encode_json!(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, event}
    end
  end

  @impl true
  def list_events(session_id, opts)
      when (is_binary(session_id) or is_nil(session_id)) and is_list(opts) do
    with {:ok, events} <- read_events(events_path(opts)) do
      {:ok, Enum.filter(events, &event_matches_session?(&1, session_id))}
    end
  end

  @impl true
  def save_prompt_history(%Tet.PromptLab.HistoryEntry{} = history, opts) when is_list(opts) do
    path = prompt_history_path(opts)
    line = history |> Tet.PromptLab.HistoryEntry.to_map() |> encode_json!()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, history}
    end
  end

  @impl true
  def list_prompt_history(opts) when is_list(opts) do
    with {:ok, history} <- read_prompt_history(prompt_history_path(opts)) do
      {:ok, Enum.sort(history, &history_newer_or_equal?/2)}
    end
  end

  @impl true
  def fetch_prompt_history(history_id, opts) when is_binary(history_id) and is_list(opts) do
    with {:ok, history} <- read_prompt_history(prompt_history_path(opts)) do
      history
      |> Enum.find(&(&1.id == history_id))
      |> case do
        nil -> {:error, :prompt_history_not_found}
        entry -> {:ok, entry}
      end
    end
  end

  # -- BD-0034: Event Log --

  @impl true
  def append_event(attrs, opts) when is_map(attrs) and is_list(opts) do
    path = events_path(opts)

    with {:ok, event} <- Tet.Event.new(attrs),
         {:ok, event} <- assign_event_sequence(event, path),
         line = event |> Tet.Event.to_map() |> encode_json!(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, event}
    end
  end

  @impl true
  def get_event(event_id, opts) when is_binary(event_id) and is_list(opts) do
    with {:ok, events} <- read_events(events_path(opts)) do
      events
      |> Enum.find(&(&1.id == event_id))
      |> case do
        nil -> {:error, :event_not_found}
        event -> {:ok, event}
      end
    end
  end

  # -- BD-0034: Artifacts --

  @impl true
  def create_artifact(attrs) when is_map(attrs) do
    with {:ok, artifact} <- Tet.ShellPolicy.Artifact.new(attrs) do
      {:ok, artifact}
    end
  end

  @impl true
  def get_artifact(artifact_id) when is_binary(artifact_id) do
    {:error, {:not_implemented, :get_artifact}}
  end

  @impl true
  def list_artifacts(session_id, opts) when is_binary(session_id) and is_list(opts) do
    path = artifacts_path(opts)

    with {:ok, artifacts} <- read_artifacts(path) do
      task_id = Keyword.get(opts, :task_id)

      filtered =
        artifacts
        |> Enum.filter(fn artifact ->
          match_session?(artifact, session_id) and match_task?(artifact, task_id)
        end)

      {:ok, filtered}
    end
  end

  # -- BD-0034: Checkpoints --

  @impl true
  def save_checkpoint(attrs, opts) when is_map(attrs) and is_list(opts) do
    path = checkpoints_path(opts)

    with {:ok, checkpoint} <- Tet.Checkpoint.new(attrs),
         line = checkpoint |> Tet.Checkpoint.to_map() |> encode_json!(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, checkpoint}
    end
  end

  @impl true
  def get_checkpoint(checkpoint_id, opts) when is_binary(checkpoint_id) and is_list(opts) do
    with {:ok, checkpoints} <- read_checkpoints(checkpoints_path(opts)) do
      checkpoints
      |> Enum.find(&(&1.id == checkpoint_id))
      |> case do
        nil -> {:error, :checkpoint_not_found}
        checkpoint -> {:ok, checkpoint}
      end
    end
  end

  @impl true
  def list_checkpoints(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, checkpoints} <- read_checkpoints(checkpoints_path(opts)) do
      {:ok, Enum.filter(checkpoints, &(&1.session_id == session_id))}
    end
  end

  @impl true
  def delete_checkpoint(checkpoint_id, opts) when is_binary(checkpoint_id) and is_list(opts) do
    path = checkpoints_path(opts)

    with {:ok, checkpoints} <- read_checkpoints(path),
         remaining <- Enum.reject(checkpoints, &(&1.id == checkpoint_id)) do
      rewrite_jsonl(path, remaining, &Tet.Checkpoint.to_map/1)
    end
  end

  # -- BD-0034: Workflow Steps --

  @impl true
  def append_step(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, step} <- Tet.WorkflowStep.new(attrs) do
      {:ok, step}
    end
  end

  @impl true
  def get_steps(session_id, opts) when is_binary(session_id) and is_list(opts) do
    # For the JSONL adapter, steps are tracked per-workflow, not in a dedicated
    # session-indexed file. This returns empty until workflow-backed step persistence
    # is fully implemented (see §12 durable execution).
    _session_id = session_id
    _opts = opts
    {:ok, []}
  end

  # -- BD-0034: Error Log --

  @impl true
  def log_error(attrs, opts) when is_map(attrs) and is_list(opts) do
    path = error_log_path(opts)

    with {:ok, error_entry} <- Tet.ErrorLog.new(attrs),
         line = error_entry |> Tet.ErrorLog.to_map() |> encode_json!(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, error_entry}
    end
  end

  @impl true
  def list_errors(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, errors} <- read_error_log(error_log_path(opts)) do
      {:ok, Enum.filter(errors, &(&1.session_id == session_id))}
    end
  end

  @impl true
  def get_error(error_id, opts) when is_binary(error_id) and is_list(opts) do
    with {:ok, errors} <- read_error_log(error_log_path(opts)) do
      errors
      |> Enum.find(&(&1.id == error_id))
      |> case do
        nil -> {:error, :error_not_found}
        error_entry -> {:ok, error_entry}
      end
    end
  end

  @impl true
  def resolve_error(error_id, opts) when is_binary(error_id) and is_list(opts) do
    path = error_log_path(opts)

    with {:ok, errors} <- read_error_log(path) do
      errors
      |> Enum.find(&(&1.id == error_id))
      |> case do
        nil ->
          {:error, :error_not_found}

        error_entry ->
          resolved_at = DateTime.utc_now() |> DateTime.to_iso8601()
          resolved = Tet.ErrorLog.resolve(error_entry, resolved_at)
          remaining = Enum.reject(errors, &(&1.id == error_id)) ++ [resolved]
          rewrite_jsonl(path, remaining, &Tet.ErrorLog.to_map/1)
          {:ok, resolved}
      end
    end
  end

  # -- BD-0034: Repair Queue --

  @impl true
  def enqueue_repair(attrs, opts) when is_map(attrs) and is_list(opts) do
    path = repairs_path(opts)

    with {:ok, repair} <- Tet.Repair.new(attrs),
         line = repair |> Tet.Repair.to_map() |> encode_json!(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, repair}
    end
  end

  @impl true
  def dequeue_repair(opts) when is_list(opts) do
    path = repairs_path(opts)

    with {:ok, repairs} <- read_repairs(path) do
      repairs
      |> Enum.find(&(&1.status == :pending))
      |> case do
        nil ->
          {:ok, nil}

        %Tet.Repair{} = repair ->
          updated_at = DateTime.utc_now() |> DateTime.to_iso8601()
          in_progress = %{repair | status: :in_progress, updated_at: updated_at}
          remaining = Enum.reject(repairs, &(&1.id == repair.id)) ++ [in_progress]

          with {:ok, :ok} <- rewrite_jsonl(path, remaining, &Tet.Repair.to_map/1) do
            {:ok, in_progress}
          end
      end
    end
  end

  @impl true
  def update_repair(repair_id, attrs, opts)
      when is_binary(repair_id) and is_map(attrs) and is_list(opts) do
    path = repairs_path(opts)

    with {:ok, repairs} <- read_repairs(path) do
      repairs
      |> Enum.find(&(&1.id == repair_id))
      |> case do
        nil ->
          {:error, :repair_not_found}

        repair ->
          updated_at = DateTime.utc_now() |> DateTime.to_iso8601()
          updated = merge_repair_attrs(repair, attrs, updated_at)
          remaining = Enum.reject(repairs, &(&1.id == repair_id)) ++ [updated]

          with {:ok, :ok} <- rewrite_jsonl(path, remaining, &Tet.Repair.to_map/1) do
            {:ok, updated}
          end
      end
    end
  end

  @impl true
  def list_repairs(opts) when is_list(opts) do
    with {:ok, repairs} <- read_repairs(repairs_path(opts)) do
      session_id = Keyword.get(opts, :session_id)
      status = Keyword.get(opts, :status)

      filtered =
        repairs
        |> maybe_filter_by_session(session_id)
        |> maybe_filter_by_status(status)

      {:ok, filtered}
    end
  end

  # -- Required behaviour callbacks: stubs for pre-existing unimplemented callbacks --

  @impl true
  def transaction(fun) when is_function(fun, 0) do
    # JSONL adapter: no real transaction semantics. Best-effort.
    try do
      case fun.() do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
        value -> {:ok, value}
      end
    rescue
      exception -> {:error, {:caught, :error, exception}}
    end
  end

  @impl true
  def create_workspace(_attrs), do: {:error, {:not_implemented, :create_workspace}}

  @impl true
  def get_workspace(_id), do: {:error, {:not_implemented, :get_workspace}}

  @impl true
  def set_trust(_id, _trust_state), do: {:error, {:not_implemented, :set_trust}}

  @impl true
  def create_session(_attrs), do: {:error, {:not_implemented, :create_session}}

  @impl true
  def update_session(_id, _attrs), do: {:error, {:not_implemented, :update_session}}

  @impl true
  def get_session(_id), do: {:error, {:not_implemented, :get_session}}

  @impl true
  def list_sessions_with_opts(_opts), do: {:error, {:not_implemented, :list_sessions_with_opts}}

  @impl true
  def create_task(_attrs), do: {:error, {:not_implemented, :create_task}}

  @impl true
  def append_message(attrs) when is_map(attrs) do
    with {:ok, message} <- Tet.Message.new(attrs) do
      {:ok, message}
    end
  end

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

  @impl true
  def emit_event(attrs) when is_map(attrs) do
    append_event(attrs, [])
  end

  @impl true
  def create_workflow(attrs) when is_map(attrs) do
    with {:ok, workflow} <- Tet.Workflow.new(attrs) do
      {:ok, workflow}
    end
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
  def list_steps(_workflow_id), do: {:ok, []}

  @impl true
  def claim_workflow(_id, _node, _ttl), do: {:ok, :claimed}

  # -- Internal readers --

  defp read_messages(path) do
    read_json_lines(path, &Tet.Message.from_map/1)
  end

  defp read_autosaves(path) do
    read_json_lines(
      path,
      &Tet.Autosave.from_map/1,
      :autosave_read_failed,
      {:invalid_autosave_record, :not_a_map}
    )
  end

  defp read_events(path) do
    read_json_lines(path, &Tet.Event.from_map/1)
  end

  defp read_prompt_history(path) do
    read_json_lines(
      path,
      &Tet.PromptLab.HistoryEntry.from_map/1,
      :prompt_history_read_failed,
      {:invalid_prompt_history_record, :not_a_map}
    )
  end

  defp read_artifacts(path) do
    read_json_lines(path, &decode_artifact/1, :artifact_read_failed, {
      :invalid_artifact_record,
      :not_a_map
    })
  end

  defp read_checkpoints(path) do
    read_json_lines(
      path,
      &Tet.Checkpoint.from_map/1,
      :checkpoint_read_failed,
      {:invalid_checkpoint_record, :not_a_map}
    )
  end

  defp read_error_log(path) do
    read_json_lines(
      path,
      &Tet.ErrorLog.from_map/1,
      :error_log_read_failed,
      {:invalid_error_log_record, :not_a_map}
    )
  end

  defp read_repairs(path) do
    read_json_lines(
      path,
      &Tet.Repair.from_map/1,
      :repair_read_failed,
      {:invalid_repair_record, :not_a_map}
    )
  end

  defp decode_artifact(map) when is_map(map) do
    Tet.ShellPolicy.Artifact.new(map)
  end

  defp match_session?(artifact, session_id) do
    artifact.task_id == session_id or artifact.tool_call_id == session_id
  end

  defp match_task?(_artifact, nil), do: true

  defp match_task?(artifact, task_id) do
    artifact.task_id == task_id
  end

  defp maybe_filter_by_session(repairs, nil), do: repairs

  defp maybe_filter_by_session(repairs, session_id) do
    Enum.filter(repairs, &(&1.session_id == session_id))
  end

  defp maybe_filter_by_status(repairs, nil), do: repairs

  defp maybe_filter_by_status(repairs, status) do
    Enum.filter(repairs, &(&1.status == status))
  end

  defp merge_repair_attrs(%Tet.Repair{} = repair, attrs, updated_at) do
    %{
      repair
      | status: Map.get(attrs, :status, Map.get(attrs, "status", repair.status)),
        result: Map.get(attrs, :result, Map.get(attrs, "result", repair.result)),
        description:
          Map.get(attrs, :description, Map.get(attrs, "description", repair.description)),
        context: Map.get(attrs, :context, Map.get(attrs, "context", repair.context)),
        updated_at: updated_at
    }
  end

  defp rewrite_jsonl(path, records, to_map_fn) do
    lines = Enum.map(records, &(&1 |> to_map_fn.() |> encode_json!()))
    content = Enum.join(lines, "\n")

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      if content == "" do
        if File.exists?(path), do: File.rm(path), else: :ok
        {:ok, :ok}
      else
        with :ok <- File.write(path, content <> "\n") do
          {:ok, :ok}
        end
      end
    end
  end

  # -- Generic JSONL reader --

  defp read_json_lines(
         path,
         decoder,
         read_error_tag \\ :store_read_failed,
         invalid_map_error \\ {:invalid_store_record, :not_a_map}
       ) do
    if File.exists?(path) do
      path
      |> File.stream!([], :line)
      |> Enum.reduce_while({:ok, []}, fn line, acc ->
        decode_line(line, acc, decoder, invalid_map_error)
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, []}
    end
  rescue
    exception in File.Error -> {:error, {read_error_tag, exception.reason}}
  end

  defp decode_line(_line, {:error, reason}, _decoder, _invalid_map_error),
    do: {:halt, {:error, reason}}

  defp decode_line(line, {:ok, records}, decoder, invalid_map_error) do
    line = String.trim(line)

    cond do
      line == "" ->
        {:cont, {:ok, records}}

      true ->
        with {:ok, decoded} <- decode_json(line),
             :ok <- ensure_record_map(decoded, invalid_map_error),
             {:ok, record} <- decoder.(decoded) do
          {:cont, {:ok, [record | records]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end
  end

  defp assign_event_sequence(%Tet.Event{sequence: sequence} = event, _path)
       when is_integer(sequence) and sequence >= 0 do
    {:ok, event}
  end

  defp assign_event_sequence(%Tet.Event{} = event, path) do
    with {:ok, events} <- read_events(path) do
      max_sequence =
        events
        |> Enum.map(&(&1.sequence || 0))
        |> Enum.max(fn -> 0 end)

      {:ok, %Tet.Event{event | sequence: max_sequence + 1}}
    end
  end

  defp event_matches_session?(_event, nil), do: true
  defp event_matches_session?(%Tet.Event{session_id: session_id}, session_id), do: true
  defp event_matches_session?(_event, _session_id), do: false

  defp session_newer_or_equal?(left, right) do
    {left.updated_at || "", left.id} >= {right.updated_at || "", right.id}
  end

  defp checkpoint_newer_or_equal?(left, right) do
    {left.saved_at || "", left.checkpoint_id} >= {right.saved_at || "", right.checkpoint_id}
  end

  defp history_newer_or_equal?(left, right) do
    {left.created_at || "", left.id} >= {right.created_at || "", right.id}
  end

  defp cleanup_created_directory(_directory, true), do: :ok

  defp cleanup_created_directory(directory, false) do
    File.rmdir(directory)
    :ok
  end

  defp assert_readable(path) do
    if File.exists?(path) do
      case File.open(path, [:read], fn _io -> :ok end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, {:not_readable, reason}}
      end
    else
      :ok
    end
  end

  defp assert_writable(directory) do
    probe_path =
      Path.join(directory, ".tet-health-#{System.unique_integer([:positive, :monotonic])}.tmp")

    result =
      with :ok <- File.write(probe_path, "ok", [:write]),
           {:ok, "ok"} <- File.read(probe_path) do
        :ok
      else
        {:error, reason} -> {:error, {:not_writable, reason}}
        other -> {:error, {:write_probe_failed, other}}
      end

    File.rm(probe_path)
    result
  end

  # -- Path helpers --

  defp path(opts) do
    Keyword.get(opts, :path) ||
      Keyword.get(opts, :store_path) ||
      System.get_env("TET_STORE_PATH") ||
      Application.get_env(:tet_runtime, :store_path, @default_path)
  end

  defp autosave_path(opts) do
    Keyword.get(opts, :autosave_path) ||
      System.get_env("TET_AUTOSAVE_PATH") ||
      Application.get_env(:tet_runtime, :autosave_path) ||
      default_autosave_path(path(opts))
  end

  defp events_path(opts) do
    Keyword.get(opts, :events_path) ||
      Keyword.get(opts, :event_path) ||
      System.get_env("TET_EVENTS_PATH") ||
      Application.get_env(:tet_runtime, :events_path) ||
      derive_events_path(path(opts))
  end

  defp prompt_history_path(opts) do
    Keyword.get(opts, :prompt_history_path) ||
      Keyword.get(opts, :prompt_lab_history_path) ||
      System.get_env("TET_PROMPT_HISTORY_PATH") ||
      Application.get_env(:tet_runtime, :prompt_history_path) ||
      default_prompt_history_path(path(opts))
  end

  defp artifacts_path(opts) do
    Keyword.get(opts, :artifacts_path) ||
      System.get_env("TET_ARTIFACTS_PATH") ||
      Application.get_env(:tet_runtime, :artifacts_path) ||
      @default_artifacts_path
  end

  defp checkpoints_path(opts) do
    Keyword.get(opts, :checkpoints_path) ||
      System.get_env("TET_CHECKPOINTS_PATH") ||
      Application.get_env(:tet_runtime, :checkpoints_path) ||
      @default_checkpoints_path
  end

  defp error_log_path(opts) do
    Keyword.get(opts, :error_log_path) ||
      System.get_env("TET_ERROR_LOG_PATH") ||
      Application.get_env(:tet_runtime, :error_log_path) ||
      @default_error_log_path
  end

  defp repairs_path(opts) do
    Keyword.get(opts, :repairs_path) ||
      System.get_env("TET_REPAIRS_PATH") ||
      Application.get_env(:tet_runtime, :repairs_path) ||
      @default_repairs_path
  end

  defp default_autosave_path(message_path) do
    message_path
    |> Path.dirname()
    |> Path.join(@default_autosave_filename)
  end

  defp default_prompt_history_path(message_path) do
    message_path
    |> Path.dirname()
    |> Path.join(@default_prompt_history_filename)
  end

  defp derive_events_path(@default_path), do: @default_events_path

  defp derive_events_path(message_path) do
    extension = Path.extname(message_path)

    if extension == "" do
      message_path <> ".events.jsonl"
    else
      Path.rootname(message_path) <> ".events" <> extension
    end
  end

  defp encode_json!(term) do
    term
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp decode_json(line) do
    {:ok, :json.decode(line)}
  rescue
    exception -> {:error, {:invalid_store_record, Exception.message(exception)}}
  end

  defp ensure_record_map(record, _invalid_map_error) when is_map(record), do: :ok
  defp ensure_record_map(_record, invalid_map_error), do: {:error, invalid_map_error}

  defp started? do
    Enum.any?(Application.started_applications(), fn {application, _description, _version} ->
      application == :tet_store_sqlite
    end)
  end
end
