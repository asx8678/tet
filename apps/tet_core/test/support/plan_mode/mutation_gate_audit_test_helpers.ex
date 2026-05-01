defmodule Tet.PlanMode.MutationGateAuditTestHelpers do
  @moduledoc """
  Shared helpers for mutation gate audit test files.

  Extracted from mutation_gate_audit_test.exs during the BD-0030
  file-size split to keep each test file focused and below the
  600-line guideline.
  """

  alias Tet.Tool.Contract
  alias Tet.Event

  import Tet.PlanMode.GateTestHelpers

  # Session ID shared across audit tests for consistent correlation.
  @session_id "ses_bd0030_audit"

  def session_id, do: @session_id

  def next_seq do
    System.unique_integer([:positive, :monotonic])
  end

  @tool_started :"tool.started"
  @tool_blocked :"tool.blocked"
  @tool_requested :"tool.requested"

  @doc """
  Maps a gate decision to the correct audit event type.
  """
  def decision_to_event_type(:allow), do: @tool_started
  def decision_to_event_type({:block, _reason}), do: @tool_blocked
  def decision_to_event_type({:guide, _msg}), do: @tool_requested
  # Sentinel for guided read-only scenario in exhaustive test
  def decision_to_event_type(:guided_read), do: @tool_requested

  @doc """
  Persists a gate decision as an auditable event.
  Returns {:ok, event} on success, {:error, reason} on failure.
  """
  def persist_decision(contract, decision, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, @session_id)
    seq = Keyword.get(opts, :seq, next_seq())

    event_type = decision_to_event_type(decision)

    payload = %{
      tool: contract.name,
      decision: decision,
      mutation: contract.mutation,
      read_only: contract.read_only
    }

    Event.new(%{
      type: event_type,
      session_id: session_id,
      seq: seq,
      payload: payload,
      metadata: %{correlation: %{session_id: session_id}}
    })
  end

  @doc """
  A write contract that also declares :verifying in task_categories,
  used to verify that verifying tasks unlock mutation.
  """
  def write_acting_verifying_contract do
    %Contract{} = base = read_contract()

    %{
      base
      | name: "write-acting-verifying",
        read_only: false,
        mutation: :write,
        modes: [:execute, :repair],
        task_categories: [:acting, :verifying, :debugging],
        execution: %{
          base.execution
          | mutates_workspace: true,
            executes_code: false,
            status: :contract_only,
            effects: [:writes_file]
        }
    }
  end
end
