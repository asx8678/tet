defmodule Tet.Approval.BlockedAction do
  @moduledoc """
  Blocked-action record struct for mutation audit — BD-0027.

  When the plan-mode gate (BD-0025) blocks a tool call, a BlockedAction
  record captures the reason, tool name, argument summary, and full
  correlation metadata. This ensures every denied mutation has an auditable
  trail, even when no approval or diff artifact is created.

  ## Correlation

  BlockedAction records are linked to Approval, DiffArtifact, and Snapshot
  records via shared `tool_call_id`, `session_id`, and `task_id` fields,
  ensuring every mutation has a complete approval/artifact/audit story.

  This module is pure data and pure functions. It does not dispatch tools,
  touch the filesystem, shell out, persist events, or ask a terminal question.
  """

  @known_block_reasons [
    :no_active_task,
    :invalid_context,
    :mode_not_allowed,
    :plan_mode_blocks_mutation,
    :category_blocks_tool
  ]

  @enforce_keys [:id, :tool_name, :reason, :tool_call_id]
  defstruct [
    :id,
    :tool_name,
    :reason,
    :tool_call_id,
    :args_summary,
    :timestamp,
    :session_id,
    :task_id,
    metadata: %{}
  ]

  @type reason :: atom()
  @type t :: %__MODULE__{
          id: binary(),
          tool_name: binary(),
          reason: reason(),
          tool_call_id: binary(),
          args_summary: map() | nil,
          timestamp: DateTime.t() | binary() | nil,
          session_id: binary() | nil,
          task_id: binary() | nil,
          metadata: map()
        }

  @doc "Returns the known block reasons from Gate.check decisions."
  @spec known_block_reasons() :: [reason()]
  def known_block_reasons, do: @known_block_reasons

  @doc """
  Builds a validated blocked-action record from atom or string keyed attributes.

  Required: `:id`, `:tool_name`, `:reason`, `:tool_call_id`.
  Optional: `:args_summary`, `:timestamp`, `:session_id`, `:task_id`,
  `:metadata` (default `%{}`).
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, tool_name} <- fetch_binary(attrs, :tool_name),
         {:ok, reason} <- fetch_reason(attrs, :reason),
         {:ok, tool_call_id} <- fetch_binary(attrs, :tool_call_id),
         {:ok, args_summary} <- fetch_optional_map(attrs, :args_summary),
         {:ok, timestamp} <- fetch_optional_timestamp(attrs, :timestamp),
         {:ok, session_id} <- fetch_optional_binary(attrs, :session_id),
         {:ok, task_id} <- fetch_optional_binary(attrs, :task_id),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         id: id,
         tool_name: tool_name,
         reason: reason,
         tool_call_id: tool_call_id,
         args_summary: args_summary,
         timestamp: timestamp,
         session_id: session_id,
         task_id: task_id,
         metadata: metadata
       }}
    end
  end

  @doc "Builds a blocked-action record or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, record} -> record
      {:error, reason} -> raise ArgumentError, "invalid blocked action: #{inspect(reason)}"
    end
  end

  @doc """
  Builds a blocked-action record from a gate decision.

  Convenience builder that extracts the reason from a `{:block, reason}`
  gate decision tuple and delegates to `new/1`.
  """
  @spec from_gate_decision(map(), {:block, reason()}) :: {:ok, t()} | {:error, term()}
  def from_gate_decision(attrs, {:block, reason}) when is_map(attrs) and is_atom(reason) do
    new(Map.put(attrs, :reason, reason))
  end

  def from_gate_decision(_attrs, _decision), do: {:error, {:not_a_block_decision, nil}}

  @doc "Converts a blocked-action record to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = record) do
    %{
      id: record.id,
      tool_name: record.tool_name,
      reason: Atom.to_string(record.reason),
      tool_call_id: record.tool_call_id,
      args_summary: record.args_summary,
      timestamp: timestamp_value(record.timestamp),
      session_id: record.session_id,
      task_id: record.task_id,
      metadata: record.metadata
    }
  end

  @doc "Converts a decoded map back to a validated blocked-action record."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Validators --

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_blocked_action_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_blocked_action_field, key}}
    end
  end

  defp fetch_reason(attrs, key) do
    case fetch_value(attrs, key) do
      reason when is_atom(reason) and not is_nil(reason) -> {:ok, reason}
      reason when is_binary(reason) -> parse_reason(reason)
      _ -> {:error, {:invalid_blocked_action_field, key}}
    end
  end

  defp parse_reason(str) when is_binary(str) do
    # Accept any atom-like string; the gate may produce custom reasons.
    # We don't restrict to @known_block_reasons for forward compatibility.
    {:ok, String.to_atom(str)}
  rescue
    ArgumentError -> {:error, {:invalid_blocked_action_field, :reason}}
  end

  defp fetch_optional_map(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_blocked_action_field, key}}
    end
  end

  defp fetch_optional_timestamp(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      %DateTime{} = value -> {:ok, value}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_blocked_action_field, key}}
    end
  end

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_blocked_action_field, key}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp timestamp_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp_value(value), do: value
end
