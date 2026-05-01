defmodule Tet.WorkflowStep do
  @moduledoc """
  Durable workflow step struct for crash-resilient multi-step execution — §12.

  Each step is an idempotently-keyed, individually durable unit within a
  `Tet.Workflow`. Steps track their own lifecycle so that crash recovery can
  resume from the last committed step rather than restarting the entire workflow.

  Status lifecycle:
      pending → running → completed
                        ↘ failed
                        ↘ cancelled

  The `idempotency_key` ensures at-most-once execution semantics within a
  workflow: re-processing a step returns `{:exists, step}` rather than
  duplicating work.

  This module is pure data and pure functions. Runtime orchestration lives
  in `tet_runtime`.
  """

  @statuses [:pending, :running, :completed, :failed, :cancelled]
  @terminal_statuses [:completed, :failed, :cancelled]

  @enforce_keys [:id, :workflow_id, :name, :idempotency_key]
  defstruct [
    :id,
    :workflow_id,
    :session_id,
    :name,
    :idempotency_key,
    :output,
    :error,
    :started_at,
    :completed_at,
    status: :pending,
    created_at: nil,
    metadata: %{}
  ]

  @type status :: :pending | :running | :completed | :failed | :cancelled
  @type t :: %__MODULE__{
          id: binary(),
          workflow_id: binary(),
          session_id: binary() | nil,
          name: binary(),
          idempotency_key: binary(),
          output: term() | nil,
          error: term() | nil,
          started_at: binary() | nil,
          completed_at: binary() | nil,
          status: status(),
          created_at: binary() | nil,
          metadata: map()
        }

  @doc "Returns valid step statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns terminal step statuses."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Builds a validated workflow step from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, workflow_id} <- fetch_binary(attrs, :workflow_id),
         {:ok, session_id} <- fetch_optional_binary(attrs, :session_id),
         {:ok, name} <- fetch_binary(attrs, :name),
         {:ok, idempotency_key} <- fetch_binary(attrs, :idempotency_key),
         {:ok, status} <- fetch_status(attrs, :status, :pending),
         {:ok, output} <- fetch_optional(attrs, :output),
         {:ok, error} <- fetch_optional(attrs, :error),
         {:ok, started_at} <- fetch_optional_binary(attrs, :started_at),
         {:ok, completed_at} <- fetch_optional_binary(attrs, :completed_at),
         {:ok, created_at} <- fetch_optional_binary(attrs, :created_at),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         id: id,
         workflow_id: workflow_id,
         session_id: session_id,
         name: name,
         idempotency_key: idempotency_key,
         status: status,
         output: output,
         error: error,
         started_at: started_at,
         completed_at: completed_at,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  @doc "Converts a workflow step to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = step) do
    %{
      id: step.id,
      workflow_id: step.workflow_id,
      name: step.name,
      idempotency_key: step.idempotency_key,
      status: Atom.to_string(step.status)
    }
    |> maybe_put(:session_id, step.session_id)
    |> maybe_put(:output, step.output)
    |> maybe_put(:error, step.error)
    |> maybe_put(:started_at, step.started_at)
    |> maybe_put(:completed_at, step.completed_at)
    |> maybe_put(:created_at, step.created_at)
    |> Map.put(:metadata, step.metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Converts a decoded map back to a validated workflow step."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Private helpers --

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_workflow_step_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_workflow_step_field, key}}
    end
  end

  defp fetch_optional(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      value -> {:ok, value}
    end
  end

  defp fetch_status(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      status when status in @statuses -> {:ok, status}
      status when is_binary(status) -> parse_status(status)
      _ -> {:error, {:invalid_workflow_step_field, key}}
    end
  end

  defp parse_status(str) when is_binary(str) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_workflow_step_field, :status}}
      atom -> {:ok, atom}
    end
  end

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      nil -> {:ok, default}
      :null -> {:ok, default}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_workflow_step_field, key}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
