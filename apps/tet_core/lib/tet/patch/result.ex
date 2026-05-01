defmodule Tet.Patch.Result do
  @moduledoc """
  Structured result of a patch apply/rollback cycle — BD-0028.

  Captures the complete lifecycle of a patch application including pre-apply
  snapshots, applied operations, verifier output, and optional rollback status.

  ## Fields

    - `tool_call_id` — provider/runtime tool-call id for correlation
    - `task_id` — optional durable task id
    - `approval_id` — optional approval id that cleared this patch
    - `applied` — list of operation maps that were successfully applied
    - `pre_snapshots` — list of `Tet.Patch.Snapshot` pre-apply captures
    - `post_snapshots` — list of `Tet.Patch.Snapshot` post-apply captures
    - `verifier_output` — output from the verifier hook (map or `Tet.ShellPolicy.Artifact`)
    - `rolled_back` — boolean indicating whether rollback occurred
    - `rollback_output` — details from the rollback phase
    - `error` — error message if the overall process failed
    - `ok` — boolean success indicator

  This struct is pure data. It is constructed by the runtime layer after
  executing the patch lifecycle.
  """

  @enforce_keys [:tool_call_id, :ok]
  defstruct [
    :tool_call_id,
    :task_id,
    :approval_id,
    :verifier_output,
    :rollback_output,
    :error,
    ok: false,
    applied: [],
    pre_snapshots: [],
    post_snapshots: [],
    rolled_back: false,
    errors: []
  ]

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          task_id: String.t() | nil,
          approval_id: String.t() | nil,
          applied: [map()],
          pre_snapshots: [Tet.Patch.Snapshot.t()],
          post_snapshots: [Tet.Patch.Snapshot.t()],
          verifier_output: map() | nil,
          rolled_back: boolean(),
          rollback_output: map() | nil,
          error: String.t() | nil,
          ok: boolean(),
          errors: [tuple()]
        }

  @doc """
  Builds a success result after a successful patch apply.
  """
  @spec success(keyword()) :: t()
  def success(opts \\ []) do
    %__MODULE__{
      tool_call_id: Keyword.fetch!(opts, :tool_call_id),
      task_id: Keyword.get(opts, :task_id),
      approval_id: Keyword.get(opts, :approval_id),
      applied: Keyword.get(opts, :applied, []),
      pre_snapshots: Keyword.get(opts, :pre_snapshots, []),
      post_snapshots: Keyword.get(opts, :post_snapshots, []),
      verifier_output: Keyword.get(opts, :verifier_output),
      rolled_back: Keyword.get(opts, :rolled_back, false),
      rollback_output: Keyword.get(opts, :rollback_output),
      ok: true
    }
  end

  @doc """
  Builds a failure result.
  """
  @spec error(keyword()) :: t()
  def error(opts \\ []) do
    %__MODULE__{
      tool_call_id: Keyword.fetch!(opts, :tool_call_id),
      task_id: Keyword.get(opts, :task_id),
      approval_id: Keyword.get(opts, :approval_id),
      applied: Keyword.get(opts, :applied, []),
      pre_snapshots: Keyword.get(opts, :pre_snapshots, []),
      post_snapshots: Keyword.get(opts, :post_snapshots, []),
      verifier_output: Keyword.get(opts, :verifier_output),
      rolled_back: Keyword.get(opts, :rolled_back, false),
      rollback_output: Keyword.get(opts, :rollback_output),
      error: Keyword.get(opts, :error, "Unknown error"),
      errors: Keyword.get(opts, :errors, []),
      ok: false
    }
  end

  @doc """
  Converts a result to a JSON-friendly map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      "ok" => result.ok,
      "tool_call_id" => result.tool_call_id,
      "task_id" => result.task_id,
      "approval_id" => result.approval_id,
      "applied" => result.applied,
      "pre_snapshots" => Enum.map(result.pre_snapshots, &Tet.Patch.Snapshot.to_map/1),
      "post_snapshots" => Enum.map(result.post_snapshots, &Tet.Patch.Snapshot.to_map/1),
      "verifier_output" => result.verifier_output,
      "rolled_back" => result.rolled_back,
      "rollback_output" => result.rollback_output,
      "error" => result.error
    }
    |> Enum.filter(fn {_k, v} -> not is_nil(v) end)
    |> Map.new()
  end
end
