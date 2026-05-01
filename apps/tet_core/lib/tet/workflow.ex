defmodule Tet.Workflow do
  alias Tet.Entity

  @moduledoc """
  Durable workflow struct for crash-resilient multi-step execution — §12.

  A workflow is a persistent parent record that tracks the lifecycle of a
  multi-step operation. Steps execute within the workflow context and are
  individually durable so that crash recovery can resume from the last
  committed step.

  Status lifecycle:
      created → running → completed
                         ↘ failed
                         ↘ paused_for_approval → running → ...

  This module is pure data and pure functions. Runtime orchestration lives
  in `tet_runtime`.
  """

  @statuses [:created, :running, :paused_for_approval, :completed, :failed, :cancelled]
  @terminal_statuses [:completed, :failed, :cancelled]

  @enforce_keys [:id, :session_id]
  defstruct [
    :id,
    :session_id,
    :task_id,
    :claimed_by,
    :claim_expires_at,
    status: :created,
    created_at: nil,
    updated_at: nil,
    metadata: %{}
  ]

  @type status :: :created | :running | :paused_for_approval | :completed | :failed | :cancelled
  @type t :: %__MODULE__{
          id: binary(),
          session_id: binary(),
          task_id: binary() | nil,
          claimed_by: binary() | nil,
          claim_expires_at: DateTime.t() | nil,
          status: status(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          metadata: map()
        }

  @doc "Returns valid workflow statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns terminal workflow statuses."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Builds a validated workflow from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, session_id} <- fetch_binary(attrs, :session_id),
         {:ok, task_id} <- fetch_optional_binary(attrs, :task_id),
         {:ok, claimed_by} <- fetch_optional_binary(attrs, :claimed_by),
         {:ok, claim_expires_at} <-
           Entity.fetch_optional_datetime(attrs, :claim_expires_at, :workflow),
         {:ok, status} <- fetch_status(attrs, :status, :created),
         {:ok, created_at} <- Entity.fetch_optional_datetime(attrs, :created_at, :workflow),
         {:ok, updated_at} <- Entity.fetch_optional_datetime(attrs, :updated_at, :workflow),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         task_id: task_id,
         claimed_by: claimed_by,
         claim_expires_at: claim_expires_at,
         status: status,
         created_at: created_at,
         updated_at: updated_at,
         metadata: metadata
       }}
    end
  end

  @doc "Converts a workflow to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = workflow) do
    %{
      id: workflow.id,
      session_id: workflow.session_id,
      status: Atom.to_string(workflow.status)
    }
    |> maybe_put(:task_id, workflow.task_id)
    |> maybe_put(:claimed_by, workflow.claimed_by)
    |> maybe_put(:claim_expires_at, Entity.datetime_to_map(workflow.claim_expires_at))
    |> maybe_put(:created_at, Entity.datetime_to_map(workflow.created_at))
    |> maybe_put(:updated_at, Entity.datetime_to_map(workflow.updated_at))
    |> Map.put(:metadata, workflow.metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Converts a decoded map back to a validated workflow."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Private helpers --

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_workflow_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_workflow_field, key}}
    end
  end

  defp fetch_status(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      status when status in @statuses -> {:ok, status}
      status when is_binary(status) -> parse_status(status)
      _ -> {:error, {:invalid_workflow_field, key}}
    end
  end

  defp parse_status(str) when is_binary(str) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_workflow_field, :status}}
      atom -> {:ok, atom}
    end
  end

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      nil -> {:ok, default}
      :null -> {:ok, default}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_workflow_field, key}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
