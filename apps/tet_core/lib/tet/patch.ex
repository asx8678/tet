defmodule Tet.Patch do
  @moduledoc """
  Pure-data facade for patch proposal, validation, and result assembly — BD-0028.

  This module is the core boundary for patch operations. It deals only with
  data validation and transformation — no file I/O, no GenServer, no shell
  execution. The runtime layer (`Tet.Runtime.Tools.Patch`) performs the
  actual filesystem operations of snapshot, apply, verifier, and rollback.

  ## Patch proposal lifecycle (pure validation)

  1. `propose/2` — accepts structured patch input: a target workspace path,
     a list of operations, and optional expected result hash.
  2. Validation — ensures operations are well-formed, paths are contained,
     operation kinds are valid.
  3. Returns `{:ok, validated_patch}` or `{:error, reason}`.

  ## Event types

  The following event types from `Tet.Event.@v03_types` are relevant:
    - `:"patch.applied"` — emitted after successful apply
    - `:"patch.failed"` — emitted after apply failure or rollback
    - `:"verifier.started"` — emitted before verifier runs
    - `:"verifier.finished"` — emitted after verifier completes
  """

  alias Tet.Patch.Operation

  @enforce_keys [:operations, :workspace_path]
  defstruct [
    :operations,
    :workspace_path,
    expected_result_hash: nil,
    tool_call_id: nil,
    task_id: nil,
    approval_id: nil
  ]

  @type t :: %__MODULE__{
          operations: [Operation.t()],
          workspace_path: String.t(),
          expected_result_hash: String.t() | nil,
          tool_call_id: String.t() | nil,
          task_id: String.t() | nil,
          approval_id: String.t() | nil
        }

  @doc """
  Validates and builds a patch proposal from attributes.

  ## Parameters

    - `attrs` — map with keys:
      - `:operations` — list of operation maps (required)
      - `:workspace_path` — workspace root path (required)
      - `:expected_result_hash` — optional sha256 hex of expected result
      - `:tool_call_id` — optional correlation id
      - `:task_id` — optional task id
      - `:approval_id` — optional approval id

  Returns `{:ok, %__MODULE__{}}` or `{:error, reason}`.
  """
  @spec propose(map()) :: {:ok, t()} | {:error, term()}
  def propose(attrs) when is_map(attrs) do
    normalized = normalize_keys(attrs)

    with {:ok, op_attrs_list} <- fetch_operations(normalized),
         {:ok, operations} <- build_operations(op_attrs_list),
         {:ok, workspace_path} <- fetch_workspace_path(normalized),
         :ok <- validate_operations_not_empty(operations),
         :ok <- validate_expected_hash(normalized) do
      patch = %__MODULE__{
        operations: operations,
        workspace_path: workspace_path,
        expected_result_hash: Map.get(normalized, :expected_result_hash),
        tool_call_id: Map.get(normalized, :tool_call_id),
        task_id: Map.get(normalized, :task_id),
        approval_id: Map.get(normalized, :approval_id)
      }

      {:ok, patch}
    end
  end

  @doc "Builds a patch or raises `ArgumentError`."
  @spec propose!(map()) :: t()
  def propose!(attrs) when is_map(attrs) do
    case propose(attrs) do
      {:ok, patch} -> patch
      {:error, reason} -> raise ArgumentError, "invalid patch proposal: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the set of file paths affected by a patch proposal.
  """
  @spec affected_paths(t()) :: [String.t()]
  def affected_paths(%__MODULE__{operations: operations}) do
    Enum.map(operations, & &1.file_path)
  end

  @doc """
  Returns the set of files that will be created by this patch.
  """
  @spec created_paths(t()) :: [String.t()]
  def created_paths(%__MODULE__{operations: operations}) do
    operations
    |> Enum.filter(&(&1.kind == :create))
    |> Enum.map(& &1.file_path)
  end

  @doc """
  Returns the set of files that will be modified by this patch.
  """
  @spec modified_paths(t()) :: [String.t()]
  def modified_paths(%__MODULE__{operations: operations}) do
    operations
    |> Enum.filter(&(&1.kind == :modify))
    |> Enum.map(& &1.file_path)
  end

  @doc """
  Returns the set of files that will be deleted by this patch.
  """
  @spec deleted_paths(t()) :: [String.t()]
  def deleted_paths(%__MODULE__{operations: operations}) do
    operations
    |> Enum.filter(&(&1.kind == :delete))
    |> Enum.map(& &1.file_path)
  end

  @doc """
  Returns a summary of the patch proposal.

  Returns a map with counts and paths grouped by operation kind.
  """
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = patch) do
    %{
      total_operations: length(patch.operations),
      creates: length(created_paths(patch)),
      modifies: length(modified_paths(patch)),
      deletes: length(deleted_paths(patch)),
      affected_files: affected_paths(patch),
      workspace_path: patch.workspace_path,
      expected_result_hash: patch.expected_result_hash
    }
  end

  @doc """
  Converts a patch to a JSON-friendly map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = patch) do
    %{
      "operations" => Enum.map(patch.operations, &Operation.to_map/1),
      "workspace_path" => patch.workspace_path,
      "expected_result_hash" => patch.expected_result_hash,
      "tool_call_id" => patch.tool_call_id,
      "task_id" => patch.task_id,
      "approval_id" => patch.approval_id
    }
    |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
    |> Map.new()
  end

  # -- Private helpers --

  defp normalize_keys(attrs) do
    Map.new(attrs, fn {key, value} ->
      {normalize_key(key), value}
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    case key do
      "operations" -> :operations
      "workspace_path" -> :workspace_path
      "workspace-path" -> :workspace_path
      "expected_result_hash" -> :expected_result_hash
      "expected-result-hash" -> :expected_result_hash
      "tool_call_id" -> :tool_call_id
      "tool-call-id" -> :tool_call_id
      "task_id" -> :task_id
      "task-id" -> :task_id
      "approval_id" -> :approval_id
      "approval-id" -> :approval_id
      _ -> :__unknown_key__
    end
  end

  defp normalize_key(key), do: key

  defp fetch_operations(attrs) do
    case Map.get(attrs, :operations) do
      list when is_list(list) -> {:ok, list}
      nil -> {:error, {:invalid_patch, :missing_operations}}
      other -> {:error, {:invalid_patch, :operations_not_list, other}}
    end
  end

  defp build_operations(op_attrs_list) do
    results =
      Enum.reduce_while(op_attrs_list, {:ok, []}, fn attrs, {:ok, acc} ->
        case Operation.new(attrs) do
          {:ok, operation} -> {:cont, {:ok, [operation | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      {:error, _} = error -> error
    end
  end

  defp fetch_workspace_path(attrs) do
    value = Map.get(attrs, :workspace_path)

    cond do
      is_binary(value) and value != "" -> {:ok, value}
      true -> {:error, {:invalid_patch, :workspace_path_required}}
    end
  end

  defp validate_operations_not_empty([]), do: {:error, {:invalid_patch, :empty_operations}}
  defp validate_operations_not_empty([_ | _]), do: :ok

  defp validate_expected_hash(attrs) do
    case Map.get(attrs, :expected_result_hash) do
      nil ->
        :ok

      hash when is_binary(hash) and byte_size(hash) == 64 ->
        :ok

      hash when is_binary(hash) ->
        {:error, {:invalid_patch, :invalid_hash_length, byte_size(hash)}}

      _other ->
        :ok
    end
  end
end
