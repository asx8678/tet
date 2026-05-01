defmodule Tet.Repair.PatchWorkflow.Gate do
  @moduledoc """
  Safety gates for the approval-gated patch workflow — BD-0060.

  Pure boolean and validation functions that enforce the invariant:
  **patches only apply after approval + checkpoint**.

  This module is pure functions. It does not execute patches, touch the
  filesystem, persist events, or manage processes.
  """

  alias Tet.Repair.PatchWorkflow

  @doc """
  Returns true only when the workflow is approved AND has a checkpoint.

  This is the critical safety gate — patching must never begin without both.
  """
  @spec can_patch?(PatchWorkflow.t()) :: boolean()
  def can_patch?(%PatchWorkflow{status: :approved, checkpoint_id: cp_id})
      when is_binary(cp_id) and cp_id != "" do
    true
  end

  def can_patch?(%PatchWorkflow{}), do: false

  @doc """
  Returns true only when the workflow is pending approval.
  """
  @spec can_approve?(PatchWorkflow.t()) :: boolean()
  def can_approve?(%PatchWorkflow{status: :pending_approval}), do: true
  def can_approve?(%PatchWorkflow{}), do: false

  @doc """
  Returns true when approved but checkpoint has not yet been taken.
  """
  @spec needs_checkpoint?(PatchWorkflow.t()) :: boolean()
  def needs_checkpoint?(%PatchWorkflow{status: :approved, checkpoint_id: nil}), do: true
  def needs_checkpoint?(%PatchWorkflow{}), do: false

  @doc """
  Validates all preconditions required to begin patching.

  Returns `{:ok, workflow}` when the workflow is ready to patch, or
  `{:error, reasons}` with a list of failing precondition atoms.

  Checked preconditions:
    - status must be `:approved`
    - `checkpoint_id` must be set
    - `approval_id` must be set
    - `plan` must be present
  """
  @spec validate_preconditions(PatchWorkflow.t()) ::
          {:ok, PatchWorkflow.t()} | {:error, [atom()]}
  def validate_preconditions(%PatchWorkflow{} = wf) do
    reasons =
      []
      |> check(:not_approved, wf.status != :approved)
      |> check(:missing_checkpoint, !is_binary(wf.checkpoint_id) or wf.checkpoint_id == "")
      |> check(:missing_approval, !is_binary(wf.approval_id) or wf.approval_id == "")
      |> check(:missing_plan, is_nil(wf.plan))

    case reasons do
      [] -> {:ok, wf}
      reasons -> {:error, Enum.reverse(reasons)}
    end
  end

  defp check(reasons, reason, true), do: [reason | reasons]
  defp check(reasons, _reason, false), do: reasons
end
