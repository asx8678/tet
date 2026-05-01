defmodule Tet.Runtime.Subagent.ResultMerge do
  @moduledoc """
  Deterministic subagent result merge for parent runtime state.

  Merge strategies:

    * `:last_wins` — later results overwrite earlier values for the same field
    * `:first_wins` — earlier results are preserved; later results for the same
      field are ignored
    * `:merge_maps` — nested maps are merged recursively; scalar conflicts
      resolve with the configured default strategy (default: `:first_wins`)

  ## Conflict resolution rules

    1. Later results never overwrite earlier **task output** for the same field
       when the merge uses `:first_wins` (the default).
    2. Task output is defined as the `:output` map keyed by field names.
    3. Non-output metadata (artifacts, status, timestamps) is always accumulated.
    4. `validate/1` ensures the merged result is internally consistent.
  """

  @doc """
  Merge a subagent result into an existing parent state map.

  ## Options

    * `:strategy` — merge strategy, one of `:last_wins`, `:first_wins`,
      `:merge_maps` (default: `:first_wins`)
    * `:on_scalar_conflict` — when using `:merge_maps`, how to resolve scalar
      conflicts: `:first_wins` or `:last_wins` (default: `:first_wins`)
    * `:sequence` — ordering hint for deterministic merge (default: 0)

  Returns `{:ok, merged_state}` or `{:error, reason}`.
  """
  @spec merge(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def merge(parent_state, result, opts \\ [])

  def merge(parent_state, result, opts) when is_list(opts) do
    strategy = Keyword.get(opts, :strategy, :first_wins)
    on_scalar_conflict = Keyword.get(opts, :on_scalar_conflict, :first_wins)

    with :ok <- validate_strategy(strategy),
         :ok <- validate_scalar_conflict(on_scalar_conflict),
         {:ok, result_map} <- normalize_result(result),
         :ok <- validate_result_status(result_map) do
      merged =
        parent_state
        |> merge_output(result_map, strategy, on_scalar_conflict)
        |> merge_artifacts(result_map)
        |> merge_metadata(result_map)
        |> merge_status(result_map)

      {:ok, merged}
    end
  end

  @doc """
  Merge a list of results into a parent state with deterministic ordering.

  Results are sorted by `metadata.sequence` (ascending), then by
  `metadata.created_at` (ascending) before merging. This ensures the same
  set of results always produces the same final output regardless of
  arrival order.

  ## Options

    Same as `merge/3`, plus:
    * `:default_sequence` — default sequence value if missing (default: 0)

  Returns `{:ok, merged_state}` or `{:error, reason}`.
  """
  @spec merge_list(map(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def merge_list(parent_state, results, opts \\ [])

  def merge_list(parent_state, results, opts) when is_list(results) do
    default_seq = Keyword.get(opts, :default_sequence, 0)

    sorted =
      results
      |> Enum.with_index()
      |> Enum.sort_by(fn {result, idx} ->
        meta = result_key(result, :metadata, %{})
        seq = Map.get(meta, :sequence, Map.get(meta, "sequence", default_seq))
        created_at = Map.get(meta, :created_at, Map.get(meta, "created_at", idx))
        {seq, created_at}
      end)
      |> Enum.map(fn {result, _idx} -> result end)

    Enum.reduce_while(sorted, {:ok, parent_state}, fn result, {:ok, acc} ->
      case merge(acc, result, opts) do
        {:ok, merged} -> {:cont, {:ok, merged}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def merge_list(_parent_state, _results, _opts) do
    {:error, :invalid_results_list}
  end

  @doc """
  Validate that a merged result (or parent state with merged results) is
  internally consistent.

  Checks:
    - `:output` is a map
    - `:artifacts` is a list
    - `:status` is one of `:success`, `:failure`, `:partial`, or nil
  """
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(state) when is_map(state) do
    with :ok <- validate_output(state),
         :ok <- validate_artifacts(state),
         :ok <- validate_status(state) do
      :ok
    end
  end

  def validate(_state), do: {:error, :invalid_state}

  # ── Private helpers ──────────────────────────────────────────────────────

  defp validate_strategy(strategy) when strategy in [:last_wins, :first_wins, :merge_maps],
    do: :ok

  defp validate_strategy(invalid),
    do: {:error, {:invalid_merge_strategy, invalid}}

  defp validate_scalar_conflict(strategy) when strategy in [:first_wins, :last_wins],
    do: :ok

  defp validate_scalar_conflict(invalid),
    do: {:error, {:invalid_scalar_conflict_strategy, invalid}}

  defp validate_result_status(result_map) do
    case result_key(result_map, :status) do
      nil ->
        :ok

      status ->
        case normalize_status(status) do
          :invalid -> {:error, {:invalid_status, status}}
          _ -> :ok
        end
    end
  end

  defp normalize_result(%Tet.Subagent.Result{} = result),
    do: {:ok, Tet.Subagent.Result.to_map(result)}

  defp normalize_result(%{} = map), do: {:ok, map}

  defp normalize_result(_other), do: {:error, :invalid_result}

  defp merge_output(parent, result_map, strategy, on_scalar_conflict) do
    parent_output = Map.get(parent, :output, %{}) |> normalize_output_keys()
    result_output = result_key(result_map, :output, %{}) |> normalize_output_keys()

    merged_output =
      case strategy do
        :last_wins ->
          Map.merge(parent_output, result_output)

        :first_wins ->
          Map.merge(result_output, parent_output)

        :merge_maps ->
          # parent is first arg (earlier), result is second arg (later)
          # first_wins means left_val (parent) wins for scalars
          deep_merge_maps(parent_output, result_output, on_scalar_conflict)
      end

    Map.put(parent, :output, merged_output)
  end

  defp merge_artifacts(parent, result_map) do
    result_artifacts = result_key(result_map, :artifacts, [])
    parent_artifacts = Map.get(parent, :artifacts, [])

    Map.put(parent, :artifacts, parent_artifacts ++ result_artifacts)
  end

  defp merge_metadata(parent, result_map) do
    result_meta = result_key(result_map, :metadata, %{})
    parent_meta = Map.get(parent, :metadata, %{})

    merged_meta =
      Map.merge(result_meta, parent_meta, fn _key, _new, existing ->
        existing
      end)

    Map.put(parent, :metadata, merged_meta)
  end

  defp merge_status(parent, result_map) do
    result_status = result_key(result_map, :status)
    current_status = Map.get(parent, :status) |> normalize_status()
    resolved = normalize_status(result_status)

    case resolved do
      nil ->
        parent

      :invalid ->
        parent

      status ->
        new_status =
          case {current_status, status} do
            {nil, s} -> s
            {:failure, _} -> :failure
            {:partial, :success} -> :partial
            {:partial, :partial} -> :partial
            {_, :failure} -> :failure
            {_, :partial} -> :partial
            {_, :success} -> :success
            _ -> current_status
          end

        Map.put(parent, :status, new_status)
    end
  end

  # Try atom key first, then string key
  defp result_key(map, key, default \\ nil) do
    case Map.get(map, key) do
      nil ->
        case Map.get(map, Atom.to_string(key)) do
          nil -> default
          value -> value
        end

      value ->
        value
    end
  end

  defp normalize_status(nil), do: nil

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status("success"), do: :success
  defp normalize_status("failure"), do: :failure
  defp normalize_status("partial"), do: :partial

  defp normalize_status(_status), do: :invalid

  # deep_merge_maps(left, right, on_scalar_conflict)
  # left = parent (earlier), right = result (later)
  # For :first_wins, left_val (parent) wins
  # For :last_wins, right_val (result) wins
  defp deep_merge_maps(left, right, on_scalar_conflict)
       when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_val, right_val ->
      cond do
        is_map(left_val) and is_map(right_val) ->
          deep_merge_maps(left_val, right_val, on_scalar_conflict)

        on_scalar_conflict == :first_wins ->
          left_val

        on_scalar_conflict == :last_wins ->
          right_val
      end
    end)
  end

  defp deep_merge_maps(left, _right, _on_scalar_conflict) when is_map(left) do
    left
  end

  defp normalize_output_keys(output) when is_map(output) do
    Enum.reduce(output, %{}, fn {key, val}, acc ->
      normalized_key = normalize_output_key(key)

      case normalized_key do
        atom when is_atom(atom) -> Map.put(acc, atom, val)
        _ -> Map.put(acc, key, val)
      end
    end)
  end

  defp normalize_output_key(key) when is_binary(key) do
    case key do
      "id" -> :id
      "kind" -> :kind
      "content" -> :content
      "sha256" -> :sha256
      "session_id" -> :session_id
      "task_id" -> :task_id
      "metadata" -> :metadata
      "created_at" -> :created_at
      "command" -> :command
      "risk" -> :risk
      "exit_code" -> :exit_code
      "stdout" -> :stdout
      "cwd" -> :cwd
      "duration_ms" -> :duration_ms
      "tool_call_id" -> :tool_call_id
      _ -> key
    end
  end

  defp normalize_output_key(key), do: key

  defp validate_output(state) do
    case Map.get(state, :output) do
      nil -> :ok
      output when is_map(output) -> :ok
      other -> {:error, {:invalid_output_type, other}}
    end
  end

  defp validate_artifacts(state) do
    case Map.get(state, :artifacts) do
      nil -> :ok
      artifacts when is_list(artifacts) -> :ok
      other -> {:error, {:invalid_artifacts_type, other}}
    end
  end

  defp validate_status(state) do
    case Map.get(state, :status) do
      nil -> :ok
      status when status in [:success, :failure, :partial] -> :ok
      "success" -> :ok
      "failure" -> :ok
      "partial" -> :ok
      other -> {:error, {:invalid_status_value, other}}
    end
  end
end
