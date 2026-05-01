defmodule Tet.Runtime.Subagent.ArtifactRouter do
  @moduledoc """
  Routes artifacts from subagent results to parent session/task stores.

  Each artifact produced by a subagent is persisted via the configured store
  adapter with routing metadata attached: source subagent identifier, timestamp,
  and a correlation ID that links the artifact back to the originating subagent
  result and task.
  """

  @doc """
  Route a list of artifacts from a subagent result to the parent session/task.

  ## Parameters

    * `store_adapter` — the configured store adapter module (e.g.
      `Tet.Store.Memory` or `Tet.Store.SQLite`)
    * `store_opts` — keyword list of options passed to the store adapter
    * `result` — a `Tet.Subagent.Result.t()` struct or map with `:id`,
      `:task_id`, `:session_id`, `:artifacts`, and `:metadata`

  For each artifact entry in the result, this function:
    1. Enriches the artifact attrs with routing metadata
    2. Builds a `Tet.Artifact` struct via `Tet.Artifact.new/1`
    3. Persists it via the store adapter's `create_artifact/2`
    4. Collects the persisted results

  Returns `{:ok, [persisted_artifact]}` or `{:error, reason}`.
  """
  @spec route(module(), keyword(), map()) :: {:ok, [map()]} | {:error, term()}
  def route(store_adapter, store_opts, result)

  def route(store_adapter, store_opts, %Tet.Subagent.Result{} = result) do
    route(store_adapter, store_opts, Tet.Subagent.Result.to_map(result))
  end

  def route(store_adapter, store_opts, result) when is_list(store_opts) and is_map(result) do
    source_subagent = get_key(result, :id)
    task_id = get_key(result, :task_id)
    session_id = get_key(result, :session_id)
    result_metadata = get_key(result, :metadata) || %{}
    correlation_id = get_key(result_metadata, :correlation_id) || source_subagent
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    raw_artifacts = get_key(result, :artifacts) || []

    enriched_artifacts =
      Enum.map(raw_artifacts, fn artifact ->
        artifact
        |> normalize_artifact_keys()
        |> Map.put(:session_id, session_id)
        |> Map.put(:task_id, task_id)
        |> Map.put(
          :metadata,
          enrich_metadata(artifact, source_subagent, correlation_id, timestamp)
        )
      end)

    persisted =
      enriched_artifacts
      |> Enum.reduce_while([], fn artifact, acc ->
        case persist_artifact(store_adapter, store_opts, artifact) do
          {:ok, persisted_artifact} -> {:cont, [persisted_artifact | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case persisted do
      {:error, _} = error -> error
      artifacts -> {:ok, Enum.reverse(artifacts)}
    end
  end

  def route(_store_adapter, _store_opts, _result), do: {:error, :invalid_result}

  @doc """
  Route a single artifact map from a subagent to the parent store.

  This is a convenience wrapper around `route/3` for single-artifact routing.
  """
  @spec route_single(module(), keyword(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def route_single(store_adapter, store_opts, artifact_map, routing \\ %{}) do
    source_subagent = get_key(routing, :source_subagent)
    session_id = get_key(routing, :session_id)
    task_id = get_key(routing, :task_id)
    correlation_id = get_key(routing, :correlation_id) || source_subagent
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    enriched =
      artifact_map
      |> normalize_artifact_keys()
      |> Map.put(:session_id, session_id)
      |> Map.put(:task_id, task_id)
      |> Map.put_new(:id, generate_artifact_id())
      |> Map.put(
        :metadata,
        enrich_metadata(artifact_map, source_subagent, correlation_id, timestamp)
      )

    persist_artifact(store_adapter, store_opts, enriched)
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp persist_artifact(store_adapter, store_opts, artifact_attrs) do
    merged_attrs = apply_defaults(artifact_attrs)

    if function_exported?(store_adapter, :create_artifact, 2) do
      case Tet.ShellPolicy.Artifact.new(merged_attrs) do
        {:ok, artifact} -> store_adapter.create_artifact(artifact, store_opts)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:store_adapter_missing_callback, :create_artifact}}
    end
  end

  defp apply_defaults(attrs) do
    Map.merge(
      %{
        command: Map.get(attrs, :command, Map.get(attrs, "command", ["unknown"])),
        risk: Map.get(attrs, :risk, Map.get(attrs, "risk", :medium)),
        exit_code: Map.get(attrs, :exit_code, Map.get(attrs, "exit_code", 0)),
        stdout: Map.get(attrs, :stdout, Map.get(attrs, "stdout", "")),
        cwd: Map.get(attrs, :cwd, Map.get(attrs, "cwd", "/")),
        duration_ms: Map.get(attrs, :duration_ms, Map.get(attrs, "duration_ms", 0)),
        tool_call_id:
          Map.get(attrs, :tool_call_id, Map.get(attrs, "tool_call_id", generate_artifact_id()))
      },
      attrs
    )
  end

  @known_keys %{
    "id" => :id,
    "kind" => :kind,
    "content" => :content,
    "sha256" => :sha256,
    "session_id" => :session_id,
    "task_id" => :task_id,
    "metadata" => :metadata,
    "created_at" => :created_at,
    "command" => :command,
    "risk" => :risk,
    "exit_code" => :exit_code,
    "stdout" => :stdout,
    "cwd" => :cwd,
    "duration_ms" => :duration_ms,
    "tool_call_id" => :tool_call_id,
    "sha_256" => :sha256
  }

  defp normalize_key(key) when is_binary(key), do: Map.get(@known_keys, key, key)
  defp normalize_key(key), do: key

  defp normalize_artifact_keys(artifact) when is_map(artifact) do
    Enum.reduce(artifact, %{}, fn {key, val}, acc ->
      Map.put(acc, normalize_key(key), val)
    end)
  end

  defp get_key(map, atom_key) do
    case Map.get(map, atom_key) do
      nil -> Map.get(map, Atom.to_string(atom_key))
      value -> value
    end
  end

  defp enrich_metadata(artifact, source_subagent, correlation_id, timestamp) do
    existing_meta = get_key(artifact, :metadata) || %{}

    existing_meta
    |> Map.put(:routed_from_subagent, source_subagent)
    |> Map.put(:routed_at, timestamp)
    |> Map.put(:correlation_id, correlation_id)
  end

  defp generate_artifact_id do
    "art_#{:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)}"
  end
end
