defmodule Tet.Approval.Approval do
  @moduledoc """
  Approval row struct for mutation gating — BD-0027.

  Every mutation that requires human approval creates a pending approval row.
  The approval tracks status lifecycle (pending → approved | rejected), the
  approver identity, rationale, and full correlation metadata linking back to
  the tool call, session, and task.

  This module is pure data and pure functions. It does not dispatch tools,
  touch the filesystem, shell out, persist events, or ask a terminal question.

  ## Status lifecycle

      pending → approved
      pending → rejected

  `approved` and `rejected` are terminal — no further transitions are valid.

  ## Correlation

  Approval rows are linked to DiffArtifact, Snapshot, and BlockedAction records
  via shared `tool_call_id`, `session_id`, and `task_id` fields, ensuring
  every mutation has a complete approval/artifact/audit story.
  """

  @statuses [:pending, :approved, :rejected]
  @terminal_statuses [:approved, :rejected]

  @transitions [
    {:pending, :approved},
    {:pending, :rejected}
  ]

  @enforce_keys [:id, :tool_call_id, :status]
  defstruct [
    :id,
    :tool_call_id,
    :status,
    :approver,
    :rationale,
    :created_at,
    :approved_at,
    :rejected_at,
    :session_id,
    :task_id,
    metadata: %{}
  ]

  @type status :: :pending | :approved | :rejected
  @type t :: %__MODULE__{
          id: binary(),
          tool_call_id: binary(),
          status: status(),
          approver: binary() | nil,
          rationale: binary() | nil,
          created_at: DateTime.t() | binary() | nil,
          approved_at: DateTime.t() | binary() | nil,
          rejected_at: DateTime.t() | binary() | nil,
          session_id: binary() | nil,
          task_id: binary() | nil,
          metadata: map()
        }

  @doc "Returns all valid approval statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns terminal statuses (no further transitions allowed)."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Returns the legal transition table as `[{from, to}]` pairs."
  @spec transitions() :: [{status(), status()}]
  def transitions, do: @transitions

  @doc "True when the status is terminal."
  @spec terminal?(status()) :: boolean()
  def terminal?(status) when status in @terminal_statuses, do: true
  def terminal?(_status), do: false

  @doc """
  Builds a validated approval from atom or string keyed attributes.

  Required: `:id`, `:tool_call_id`, `:status`.
  Optional: `:approver`, `:rationale`, `:created_at`, `:approved_at`,
  `:rejected_at`, `:session_id`, `:task_id`, `:metadata` (default `%{}`).
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, tool_call_id} <- fetch_binary(attrs, :tool_call_id),
         {:ok, status} <- fetch_status(attrs, :status, :pending),
         {:ok, approver} <- fetch_optional_binary(attrs, :approver),
         {:ok, rationale} <- fetch_optional_binary(attrs, :rationale),
         {:ok, created_at} <- fetch_optional_timestamp(attrs, :created_at),
         {:ok, approved_at} <- fetch_optional_timestamp(attrs, :approved_at),
         {:ok, rejected_at} <- fetch_optional_timestamp(attrs, :rejected_at),
         {:ok, session_id} <- fetch_optional_binary(attrs, :session_id),
         {:ok, task_id} <- fetch_optional_binary(attrs, :task_id),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}),
         :ok <- validate_timestamp_consistency(status, approved_at, rejected_at) do
      {:ok,
       %__MODULE__{
         id: id,
         tool_call_id: tool_call_id,
         status: status,
         approver: approver,
         rationale: rationale,
         created_at: created_at,
         approved_at: approved_at,
         rejected_at: rejected_at,
         session_id: session_id,
         task_id: task_id,
         metadata: metadata
       }}
    end
  end

  @doc "Builds an approval or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, approval} -> approval
      {:error, reason} -> raise ArgumentError, "invalid approval: #{inspect(reason)}"
    end
  end

  @doc """
  Transitions an approval to a new status.

  Returns `{:ok, approval}` when the transition is legal, or
  `{:error, {:invalid_approval_transition, from, to}}` when it is not.
  Terminal approvals reject all transitions.
  """
  @spec transition(t(), status()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{status: from} = approval, to) when to in @statuses do
    if {from, to} in @transitions do
      {:ok, %__MODULE__{approval | status: to}}
    else
      {:error, {:invalid_approval_transition, from, to}}
    end
  end

  def transition(%__MODULE__{status: from}, to) do
    {:error, {:invalid_approval_transition, from, to}}
  end

  @doc "Approves a pending approval (pending → approved)."
  @spec approve(t(), binary(), binary()) :: {:ok, t()} | {:error, term()}
  def approve(%__MODULE__{} = approval, approver, rationale)
      when is_binary(approver) and is_binary(rationale) do
    case transition(approval, :approved) do
      {:ok, updated} ->
        {:ok,
         %__MODULE__{
           updated
           | approver: approver,
             rationale: rationale,
             approved_at: DateTime.utc_now()
         }}

      {:error, _} = error ->
        error
    end
  end

  def approve(%__MODULE__{}, _approver, _rationale) do
    {:error, {:invalid_approver_or_rationale, nil}}
  end

  @doc "Rejects a pending approval (pending → rejected)."
  @spec reject(t(), binary(), binary()) :: {:ok, t()} | {:error, term()}
  def reject(%__MODULE__{} = approval, approver, rationale)
      when is_binary(approver) and is_binary(rationale) do
    case transition(approval, :rejected) do
      {:ok, updated} ->
        {:ok,
         %__MODULE__{
           updated
           | approver: approver,
             rationale: rationale,
             rejected_at: DateTime.utc_now()
         }}

      {:error, _} = error ->
        error
    end
  end

  def reject(%__MODULE__{}, _approver, _rationale) do
    {:error, {:invalid_approver_or_rationale, nil}}
  end

  @doc "Converts an approval to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = approval) do
    %{
      id: approval.id,
      tool_call_id: approval.tool_call_id,
      status: Atom.to_string(approval.status),
      approver: approval.approver,
      rationale: approval.rationale,
      created_at: timestamp_value(approval.created_at),
      approved_at: timestamp_value(approval.approved_at),
      rejected_at: timestamp_value(approval.rejected_at),
      session_id: approval.session_id,
      task_id: approval.task_id,
      metadata: approval.metadata
    }
  end

  @doc "Converts a decoded map back to a validated approval."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Validators --

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_approval_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_approval_field, key}}
    end
  end

  defp fetch_status(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      status when status in @statuses -> {:ok, status}
      status when is_binary(status) -> parse_status(status)
      _ -> {:error, {:invalid_approval_field, key}}
    end
  end

  defp parse_status(str) when is_binary(str) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_approval_field, :status}}
      atom -> {:ok, atom}
    end
  end

  defp fetch_optional_timestamp(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      %DateTime{} = value -> {:ok, value}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_approval_field, key}}
    end
  end

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_approval_field, key}}
    end
  end

  defp validate_timestamp_consistency(:approved, nil, _rejected_at) do
    {:error, {:invalid_approval_field, :approved_at}}
  end

  defp validate_timestamp_consistency(:approved, _approved_at, _rejected_at), do: :ok

  defp validate_timestamp_consistency(:rejected, _approved_at, nil) do
    {:error, {:invalid_approval_field, :rejected_at}}
  end

  defp validate_timestamp_consistency(:rejected, _approved_at, _rejected_at), do: :ok

  defp validate_timestamp_consistency(:pending, nil, nil), do: :ok

  defp validate_timestamp_consistency(:pending, _approved_at, _rejected_at) do
    {:error, {:pending_approval_has_terminal_timestamp, nil}}
  end

  defp validate_timestamp_consistency(_status, _approved_at, _rejected_at), do: :ok

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp timestamp_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp_value(value), do: value
end
