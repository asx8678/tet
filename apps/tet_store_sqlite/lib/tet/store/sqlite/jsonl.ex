defmodule Tet.Store.SQLite.Jsonl do
  @moduledoc """
  JSONL read/write infrastructure for non-core store callbacks.

  Core callbacks (workspace, session, message, event) are Repo-backed in
  `Tet.Store.SQLite`. This module exists only until tet-3fp rewrites the
  remaining JSONL callbacks to use Repo. Then it can be deleted—no tears shed.
  """

  # -- Path defaults --

  @default_path ".tet/messages.jsonl"
  @default_autosave_filename "autosaves.jsonl"
  @default_prompt_history_filename "prompt_history.jsonl"
  @default_events_path ".tet/events.jsonl"
  @default_artifacts_path ".tet/artifacts.jsonl"
  @default_checkpoints_path ".tet/checkpoints.jsonl"
  @default_error_log_path ".tet/error_log.jsonl"
  @default_workflow_steps_path ".tet/workflow_steps.jsonl"
  @default_repairs_path ".tet/repairs.jsonl"
  @default_findings_path ".tet/findings.jsonl"
  @default_persistent_memories_path ".tet/persistent_memories.jsonl"
  @default_project_lessons_path ".tet/project_lessons.jsonl"

  @doc "Returns default paths for boundary/health reporting."
  def defaults do
    %{
      path: @default_path,
      events_path: derive_events_path(@default_path),
      autosave_path: default_autosave_path(@default_path),
      prompt_history_path: default_prompt_history_path(@default_path)
    }
  end

  # -- Path resolution --

  def path(opts) do
    Keyword.get(opts, :path) ||
      Keyword.get(opts, :store_path) ||
      System.get_env("TET_STORE_PATH") ||
      Application.get_env(:tet_runtime, :store_path, @default_path)
  end

  def autosave_path(opts) do
    Keyword.get(opts, :autosave_path) ||
      System.get_env("TET_AUTOSAVE_PATH") ||
      Application.get_env(:tet_runtime, :autosave_path) ||
      default_autosave_path(path(opts))
  end

  def events_path(opts) do
    Keyword.get(opts, :events_path) ||
      Keyword.get(opts, :event_path) ||
      System.get_env("TET_EVENTS_PATH") ||
      Application.get_env(:tet_runtime, :events_path) ||
      derive_events_path(path(opts))
  end

  def prompt_history_path(opts) do
    Keyword.get(opts, :prompt_history_path) ||
      Keyword.get(opts, :prompt_lab_history_path) ||
      System.get_env("TET_PROMPT_HISTORY_PATH") ||
      Application.get_env(:tet_runtime, :prompt_history_path) ||
      default_prompt_history_path(path(opts))
  end

  def artifacts_path(opts) do
    Keyword.get(opts, :artifacts_path) ||
      System.get_env("TET_ARTIFACTS_PATH") ||
      Application.get_env(:tet_runtime, :artifacts_path) ||
      @default_artifacts_path
  end

  def checkpoints_path(opts) do
    Keyword.get(opts, :checkpoints_path) ||
      System.get_env("TET_CHECKPOINTS_PATH") ||
      Application.get_env(:tet_runtime, :checkpoints_path) ||
      @default_checkpoints_path
  end

  def error_log_path(opts) do
    Keyword.get(opts, :error_log_path) ||
      System.get_env("TET_ERROR_LOG_PATH") ||
      Application.get_env(:tet_runtime, :error_log_path) ||
      @default_error_log_path
  end

  def repairs_path(opts) do
    Keyword.get(opts, :repairs_path) ||
      System.get_env("TET_REPAIRS_PATH") ||
      Application.get_env(:tet_runtime, :repairs_path) ||
      @default_repairs_path
  end

  def workflow_steps_path(opts) do
    Keyword.get(opts, :workflow_steps_path) ||
      System.get_env("TET_WORKFLOW_STEPS_PATH") ||
      Application.get_env(:tet_runtime, :workflow_steps_path) ||
      @default_workflow_steps_path
  end

  def findings_path(opts) do
    Keyword.get(opts, :findings_path) ||
      System.get_env("TET_FINDINGS_PATH") ||
      Application.get_env(:tet_runtime, :findings_path) ||
      @default_findings_path
  end

  def persistent_memories_path(opts) do
    Keyword.get(opts, :persistent_memories_path) ||
      System.get_env("TET_PERSISTENT_MEMORIES_PATH") ||
      Application.get_env(:tet_runtime, :persistent_memories_path) ||
      @default_persistent_memories_path
  end

  def project_lessons_path(opts) do
    Keyword.get(opts, :project_lessons_path) ||
      System.get_env("TET_PROJECT_LESSONS_PATH") ||
      Application.get_env(:tet_runtime, :project_lessons_path) ||
      @default_project_lessons_path
  end

  # -- Common JSONL operations --

  @doc "Appends a single record as a JSONL line to `path`."
  def append_record(path, struct, to_map_fn) do
    line = struct |> to_map_fn.() |> encode_json!()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, struct}
    end
  end

  @doc "Finds a record by id in a JSONL file using the given reader."
  def find_by_id(path, reader_fn, id, not_found_error) do
    with {:ok, records} <- reader_fn.(path) do
      case Enum.find(records, &(&1.id == id)) do
        nil -> {:error, not_found_error}
        record -> {:ok, record}
      end
    end
  end

  @doc "Rewrites an entire JSONL file from a list of records."
  def rewrite(path, records, to_map_fn) do
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

  # -- Entity readers --

  def read_autosaves(path) do
    read_json_lines(path, &Tet.Autosave.from_map/1, :autosave_read_failed, {
      :invalid_autosave_record,
      :not_a_map
    })
  end

  def read_prompt_history(path) do
    read_json_lines(
      path,
      &Tet.PromptLab.HistoryEntry.from_map/1,
      :prompt_history_read_failed,
      {:invalid_prompt_history_record, :not_a_map}
    )
  end

  def read_artifacts(path) do
    read_json_lines(path, &decode_artifact/1, :artifact_read_failed, {
      :invalid_artifact_record,
      :not_a_map
    })
  end

  def read_checkpoints(path) do
    read_json_lines(
      path,
      &Tet.Checkpoint.from_map/1,
      :checkpoint_read_failed,
      {:invalid_checkpoint_record, :not_a_map}
    )
  end

  def read_error_log(path) do
    read_json_lines(
      path,
      &Tet.ErrorLog.from_map/1,
      :error_log_read_failed,
      {:invalid_error_log_record, :not_a_map}
    )
  end

  def read_repairs(path) do
    read_json_lines(
      path,
      &Tet.Repair.from_map/1,
      :repair_read_failed,
      {:invalid_repair_record, :not_a_map}
    )
  end

  def read_workflow_steps(path) do
    read_json_lines(
      path,
      &Tet.WorkflowStep.from_map/1,
      :workflow_step_read_failed,
      {:invalid_workflow_step_record, :not_a_map}
    )
  end

  def read_findings(path) do
    read_json_lines(
      path,
      &Tet.Finding.from_map/1,
      :finding_read_failed,
      {:invalid_finding_record, :not_a_map}
    )
  end

  def read_persistent_memories(path) do
    read_json_lines(
      path,
      &Tet.PersistentMemory.from_map/1,
      :persistent_memory_read_failed,
      {:invalid_persistent_memory_record, :not_a_map}
    )
  end

  def read_project_lessons(path) do
    read_json_lines(
      path,
      &Tet.ProjectLesson.from_map/1,
      :project_lesson_read_failed,
      {:invalid_project_lesson_record, :not_a_map}
    )
  end

  # -- Artifact helpers --

  def match_session?(artifact, session_id) do
    artifact.session_id == session_id or
      artifact.task_id == session_id or
      artifact.tool_call_id == session_id
  end

  def match_task?(_artifact, nil), do: true
  def match_task?(artifact, task_id), do: artifact.task_id == task_id

  # -- Comparison helpers --

  def checkpoint_newer_or_equal?(left, right) do
    {left.saved_at || "", left.checkpoint_id} >= {right.saved_at || "", right.checkpoint_id}
  end

  def history_newer_or_equal?(left, right) do
    {left.created_at || "", left.id} >= {right.created_at || "", right.id}
  end

  # -- Health/utility --

  def assert_readable(path) do
    if File.exists?(path) do
      case File.open(path, [:read], fn _io -> :ok end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, {:not_readable, reason}}
      end
    else
      :ok
    end
  end

  def assert_writable(directory) do
    probe = Path.join(directory, ".tet-health-#{System.unique_integer([:positive, :monotonic])}.tmp")

    result =
      with :ok <- File.write(probe, "ok", [:write]),
           {:ok, "ok"} <- File.read(probe) do
        :ok
      else
        {:error, reason} -> {:error, {:not_writable, reason}}
        other -> {:error, {:write_probe_failed, other}}
      end

    File.rm(probe)
    result
  end

  def cleanup_created_directory(_directory, true), do: :ok

  def cleanup_created_directory(directory, false) do
    File.rmdir(directory)
    :ok
  end

  def started? do
    Enum.any?(Application.started_applications(), fn {app, _, _} ->
      app == :tet_store_sqlite
    end)
  end

  # -- Encode/decode --

  def encode_json!(term) do
    term |> :json.encode() |> IO.iodata_to_binary()
  end

  # -- Private --

  defp decode_artifact(map) when is_map(map), do: Tet.ShellPolicy.Artifact.new(map)

  defp default_autosave_path(message_path) do
    message_path |> Path.dirname() |> Path.join(@default_autosave_filename)
  end

  defp default_prompt_history_path(message_path) do
    message_path |> Path.dirname() |> Path.join(@default_prompt_history_filename)
  end

  defp derive_events_path(@default_path), do: @default_events_path

  defp derive_events_path(message_path) do
    ext = Path.extname(message_path)
    if ext == "", do: message_path <> ".events.jsonl", else: Path.rootname(message_path) <> ".events" <> ext
  end

  defp read_json_lines(path, decoder, read_error_tag, invalid_map_error) do
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

    if line == "" do
      {:cont, {:ok, records}}
    else
      with {:ok, decoded} <- decode_json(line),
           :ok <- ensure_record_map(decoded, invalid_map_error),
           {:ok, record} <- decoder.(decoded) do
        {:cont, {:ok, [record | records]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end
  end

  defp decode_json(line) do
    {:ok, :json.decode(line)}
  rescue
    exception -> {:error, {:invalid_store_record, Exception.message(exception)}}
  end

  defp ensure_record_map(record, _) when is_map(record), do: :ok
  defp ensure_record_map(_, invalid_map_error), do: {:error, invalid_map_error}
end
