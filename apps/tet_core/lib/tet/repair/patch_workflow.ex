defmodule Tet.Repair.PatchWorkflow do
  @moduledoc """
  Approval-gated repair patch workflow — BD-0060.

  A patch workflow converts a repair plan into an actionable patch sequence,
  but patches only apply after explicit approval and a safety checkpoint.

  ## Lifecycle

      :pending_approval → :approved    (via `approve/2`)
      :pending_approval → :rejected    (via `reject/1`)
      :approved         → :patching    (via `begin_patching/1`, requires checkpoint)
      :patching         → :succeeded   (via `succeed/1`)
      :patching         → :failed      (via `fail/2`)
      :failed           → :rolled_back (via `rollback/1`)
      :succeeded        → :rolled_back (via `rollback/1`)

  Truly terminal statuses (no further transitions): `:rejected` and `:rolled_back`.
  Note that `:succeeded` and `:failed` can still transition to `:rolled_back`,
  so they are *not* terminal.

  This module is pure data and pure functions. It does not execute patches,
  touch the filesystem, persist events, or manage processes.
  """

  alias Tet.Entity

  @statuses [
    :pending_approval,
    :approved,
    :patching,
    :succeeded,
    :failed,
    :rejected,
    :rolled_back
  ]

  @terminal_statuses [:rejected, :rolled_back]

  @enforce_keys [:id, :repair_id, :plan]
  defstruct [
    :id,
    :repair_id,
    :session_id,
    :plan,
    :checkpoint_id,
    :approval_id,
    status: :pending_approval,
    patches_applied: [],
    created_at: nil,
    completed_at: nil
  ]

  @type status ::
          :pending_approval
          | :approved
          | :patching
          | :succeeded
          | :failed
          | :rejected
          | :rolled_back

  @type plan :: %{
          required(:description) => binary(),
          required(:files) => [binary()],
          required(:changes) => list()
        }

  @type t :: %__MODULE__{
          id: binary(),
          repair_id: binary(),
          session_id: binary() | nil,
          plan: plan(),
          checkpoint_id: binary() | nil,
          approval_id: binary() | nil,
          status: status(),
          patches_applied: list(),
          created_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @doc "Returns all valid workflow statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  Returns terminal statuses (no further transitions).

  Only `:rejected` and `:rolled_back` are truly terminal —
  `:succeeded` and `:failed` can still transition to `:rolled_back`.
  """
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc """
  Creates a new patch workflow from attributes.

  Required: `:repair_id`, `:plan` (map with `:description`, `:files`, `:changes`).
  Optional: `:id` (auto-generated if omitted), `:session_id`, `:created_at`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_or_generate_id(attrs),
         {:ok, repair_id} <- Entity.fetch_required_binary(attrs, :repair_id, :patch_workflow),
         {:ok, session_id} <- Entity.fetch_optional_binary(attrs, :session_id, :patch_workflow),
         {:ok, plan} <- fetch_plan(attrs),
         {:ok, created_at} <- Entity.fetch_optional_datetime(attrs, :created_at, :patch_workflow) do
      {:ok,
       %__MODULE__{
         id: id,
         repair_id: repair_id,
         session_id: session_id,
         plan: plan,
         status: :pending_approval,
         patches_applied: [],
         created_at: created_at || DateTime.utc_now()
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_patch_workflow}

  @doc """
  Records an approval request ID on a pending workflow.

  Only valid when status is `:pending_approval`.
  """
  @spec request_approval(t(), binary()) :: {:ok, t()} | {:error, term()}
  def request_approval(%__MODULE__{status: :pending_approval} = wf, approval_id)
      when is_binary(approval_id) and approval_id != "" do
    {:ok, %__MODULE__{wf | approval_id: approval_id}}
  end

  def request_approval(%__MODULE__{status: :pending_approval}, ""),
    do: {:error, :empty_approval_id}

  def request_approval(%__MODULE__{status: status}, _approval_id) do
    {:error, {:invalid_transition, :request_approval, status}}
  end

  @doc """
  Approves the workflow and transitions to `:approved`.

  Only valid from `:pending_approval`. Records the approval ID.
  """
  @spec approve(t(), binary()) :: {:ok, t()} | {:error, term()}
  def approve(%__MODULE__{status: :pending_approval} = wf, approval_id)
      when is_binary(approval_id) and approval_id != "" do
    {:ok, %__MODULE__{wf | status: :approved, approval_id: approval_id}}
  end

  def approve(%__MODULE__{status: :pending_approval}, ""), do: {:error, :empty_approval_id}

  def approve(%__MODULE__{status: status}, _approval_id) do
    {:error, {:invalid_transition, :approve, status}}
  end

  @doc """
  Rejects the workflow. Terminal state — no further transitions.

  Only valid from `:pending_approval`.
  """
  @spec reject(t()) :: {:ok, t()} | {:error, term()}
  def reject(%__MODULE__{status: :pending_approval} = wf) do
    {:ok, %__MODULE__{wf | status: :rejected, completed_at: DateTime.utc_now()}}
  end

  def reject(%__MODULE__{status: status}) do
    {:error, {:invalid_transition, :reject, status}}
  end

  @doc """
  Records a checkpoint ID taken before patching begins.

  Only valid when status is `:approved`.
  """
  @spec take_checkpoint(t(), binary()) :: {:ok, t()} | {:error, term()}
  def take_checkpoint(%__MODULE__{status: :approved} = wf, checkpoint_id)
      when is_binary(checkpoint_id) and checkpoint_id != "" do
    {:ok, %__MODULE__{wf | checkpoint_id: checkpoint_id}}
  end

  def take_checkpoint(%__MODULE__{status: :approved}, ""), do: {:error, :empty_checkpoint_id}

  def take_checkpoint(%__MODULE__{status: status}, _checkpoint_id) do
    {:error, {:invalid_transition, :take_checkpoint, status}}
  end

  @doc """
  Transitions from `:approved` to `:patching`.

  Requires checkpoint_id to be set (safety invariant).
  """
  @spec begin_patching(t()) :: {:ok, t()} | {:error, term()}
  def begin_patching(%__MODULE__{status: :approved, checkpoint_id: cp_id} = wf)
      when is_binary(cp_id) and cp_id != "" do
    {:ok, %__MODULE__{wf | status: :patching}}
  end

  def begin_patching(%__MODULE__{status: :approved, checkpoint_id: nil}) do
    {:error, :checkpoint_required_before_patching}
  end

  def begin_patching(%__MODULE__{status: status}) do
    {:error, {:invalid_transition, :begin_patching, status}}
  end

  @doc """
  Appends a patch result to the workflow's applied patches list.

  Only valid while `:patching`.
  """
  @spec record_patch(t(), map()) :: {:ok, t()} | {:error, term()}
  def record_patch(%__MODULE__{status: :patching} = wf, patch_result)
      when is_map(patch_result) do
    {:ok, %__MODULE__{wf | patches_applied: wf.patches_applied ++ [patch_result]}}
  end

  def record_patch(%__MODULE__{status: status}, _patch_result) do
    {:error, {:invalid_transition, :record_patch, status}}
  end

  @doc """
  Marks the workflow as succeeded. Terminal state.

  Only valid from `:patching`.
  """
  @spec succeed(t()) :: {:ok, t()} | {:error, term()}
  def succeed(%__MODULE__{status: :patching} = wf) do
    {:ok, %__MODULE__{wf | status: :succeeded, completed_at: DateTime.utc_now()}}
  end

  def succeed(%__MODULE__{status: status}) do
    {:error, {:invalid_transition, :succeed, status}}
  end

  @doc """
  Marks the workflow as failed with a reason. Terminal state.

  Only valid from `:patching`.
  """
  @spec fail(t(), binary()) :: {:ok, t()} | {:error, term()}
  def fail(%__MODULE__{status: :patching} = wf, reason)
      when is_binary(reason) do
    {:ok, %__MODULE__{wf | status: :failed, completed_at: DateTime.utc_now()}}
  end

  def fail(%__MODULE__{status: status}, _reason) do
    {:error, {:invalid_transition, :fail, status}}
  end

  @doc """
  Marks the workflow as rolled back. Terminal state.

  Valid from `:failed` or `:succeeded` (post-hoc rollback).
  """
  @spec rollback(t()) :: {:ok, t()} | {:error, term()}
  def rollback(%__MODULE__{status: status} = wf)
      when status in [:failed, :succeeded] do
    {:ok, %__MODULE__{wf | status: :rolled_back, completed_at: DateTime.utc_now()}}
  end

  def rollback(%__MODULE__{status: status}) do
    {:error, {:invalid_transition, :rollback, status}}
  end

  # -- Private helpers --

  defp fetch_or_generate_id(attrs) do
    case Entity.fetch_value(attrs, :id) do
      nil -> {:ok, generate_id()}
      "" -> {:ok, generate_id()}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_entity_field, :patch_workflow, :id}}
    end
  end

  defp generate_id do
    "pwf_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  defp fetch_plan(attrs) do
    case Entity.fetch_value(attrs, :plan) do
      %{description: desc, files: files, changes: changes} = plan
      when is_binary(desc) and is_list(files) and is_list(changes) ->
        {:ok, plan}

      %{"description" => desc, "files" => files, "changes" => changes}
      when is_binary(desc) and is_list(files) and is_list(changes) ->
        {:ok, %{description: desc, files: files, changes: changes}}

      nil ->
        {:error, {:invalid_entity_field, :patch_workflow, :plan}}

      _ ->
        {:error, {:invalid_entity_field, :patch_workflow, :plan}}
    end
  end
end
