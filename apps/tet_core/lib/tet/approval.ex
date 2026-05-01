defmodule Tet.Approval do
  @moduledoc """
  Core human-approval entity for write operations.

  The v0.3 §04 status spelling is `:rejected`, not `:denied`. Yes, naming
  matters; future migrations should not have to translate vibes. §04 also makes
  `diff_artifact_id` required for approval rows.
  """

  alias Tet.Entity

  @statuses [:pending, :approved, :rejected]

  @enforce_keys [
    :id,
    :session_id,
    :tool_run_id,
    :status,
    :reason,
    :diff_artifact_id,
    :created_at,
    :updated_at
  ]
  defstruct [
    :id,
    :session_id,
    :task_id,
    :tool_run_id,
    :status,
    :reason,
    :diff_artifact_id,
    :resolved_at,
    :created_at,
    :updated_at,
    metadata: %{}
  ]

  @type status :: :pending | :approved | :rejected
  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          task_id: String.t() | nil,
          tool_run_id: String.t(),
          status: status(),
          reason: String.t(),
          diff_artifact_id: String.t(),
          resolved_at: DateTime.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          metadata: map()
        }

  @doc "Returns accepted approval statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds an approval from atom- or string-keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :approval),
         {:ok, session_id} <- Entity.fetch_required_binary(attrs, :session_id, :approval),
         {:ok, task_id} <- Entity.fetch_optional_binary(attrs, :task_id, :approval),
         {:ok, tool_run_id} <- Entity.fetch_required_binary(attrs, :tool_run_id, :approval),
         {:ok, status} <- Entity.fetch_atom(attrs, :status, @statuses, :approval),
         {:ok, reason} <- Entity.fetch_binary_or_nil(attrs, :reason, :approval),
         {:ok, diff_artifact_id} <-
           Entity.fetch_required_binary(attrs, :diff_artifact_id, :approval),
         {:ok, resolved_at} <- Entity.fetch_optional_datetime(attrs, :resolved_at, :approval),
         {:ok, created_at} <- Entity.fetch_required_datetime(attrs, :created_at, :approval),
         {:ok, updated_at} <- Entity.fetch_required_datetime(attrs, :updated_at, :approval),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :approval) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         task_id: task_id,
         tool_run_id: tool_run_id,
         status: status,
         reason: reason || "",
         diff_artifact_id: diff_artifact_id,
         resolved_at: resolved_at,
         created_at: created_at,
         updated_at: updated_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_approval}

  @doc "Converts a decoded map back to an approval."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Converts the approval to a map with stable string enums and timestamps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = approval) do
    %{
      id: approval.id,
      session_id: approval.session_id,
      task_id: approval.task_id,
      tool_run_id: approval.tool_run_id,
      status: Atom.to_string(approval.status),
      reason: approval.reason,
      diff_artifact_id: approval.diff_artifact_id,
      resolved_at: Entity.datetime_to_map(approval.resolved_at),
      created_at: Entity.datetime_to_map(approval.created_at),
      updated_at: Entity.datetime_to_map(approval.updated_at),
      metadata: approval.metadata
    }
  end
end
