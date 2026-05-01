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

  Additional statuses for finer-grained tracking:
      pending → started → committed
                        ↘ failed

  The `idempotency_key` ensures at-most-once execution semantics within a
  workflow: re-processing a step returns `{:exists, step}` rather than
  duplicating work.

  ## Backward compatibility

  The struct fields `step_name` and `committed_at` are the canonical names.
  `name` and `completed_at` are accepted as aliases in `new/1` / `from_map/1`.
  """

  @statuses [:pending, :started, :running, :committed, :completed, :failed, :cancelled]
  @terminal_statuses [:committed, :completed, :failed, :cancelled]

  @enforce_keys [:id, :workflow_id, :step_name, :idempotency_key]
  defstruct [
    :id,
    :workflow_id,
    :session_id,
    :step_name,
    :idempotency_key,
    :input,
    :output,
    :error,
    :started_at,
    :committed_at,
    :attempt,
    status: :pending,
    created_at: nil,
    metadata: %{}
  ]

  @type status :: :pending | :started | :running | :committed | :completed | :failed | :cancelled
  @type t :: %__MODULE__{
          id: binary(),
          workflow_id: binary(),
          session_id: binary() | nil,
          step_name: binary(),
          idempotency_key: binary(),
          input: term() | nil,
          output: term() | nil,
          error: term() | nil,
          started_at: binary() | nil,
          committed_at: binary() | nil,
          attempt: integer() | nil,
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
         {:ok, name} <- fetch_step_name(attrs),
         {:ok, idempotency_key} <- fetch_binary(attrs, :idempotency_key),
         {:ok, status} <- fetch_status(attrs, :status, :pending),
         {:ok, input} <- fetch_optional(attrs, :input),
         {:ok, output} <- fetch_optional(attrs, :output),
         {:ok, error} <- fetch_optional(attrs, :error),
         {:ok, started_at} <- fetch_optional_binary(attrs, :started_at),
         {:ok, completed_at} <- fetch_committed_at(attrs),
         {:ok, attempt} <- fetch_optional_integer(attrs, :attempt),
         {:ok, created_at} <- fetch_optional_binary(attrs, :created_at),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         id: id,
         workflow_id: workflow_id,
         session_id: session_id,
         step_name: name,
         idempotency_key: idempotency_key,
         status: status,
         input: input,
         output: output,
         error: error,
         started_at: started_at,
         committed_at: completed_at,
         attempt: attempt,
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
      step_name: step.step_name,
      idempotency_key: step.idempotency_key,
      status: Atom.to_string(step.status)
    }
    |> maybe_put(:session_id, step.session_id)
    |> maybe_put(:input, step.input)
    |> maybe_put(:output, step.output)
    |> maybe_put(:error, step.error)
    |> maybe_put(:started_at, step.started_at)
    |> maybe_put(:committed_at, step.committed_at)
    |> maybe_put(:attempt, step.attempt)
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

  defp fetch_optional_integer(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, {:invalid_workflow_step_field, key}}
    end
  end

  # Accepts both :step_name (canonical) and :name (legacy alias)
  defp fetch_step_name(attrs) do
    case fetch_value(attrs, :step_name) do
      nil ->
        case fetch_value(attrs, :name) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, {:invalid_workflow_step_field, :step_name}}
        end

      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, {:invalid_workflow_step_field, :step_name}}
    end
  end

  # Accepts both :committed_at (canonical) and :completed_at (legacy alias)
  defp fetch_committed_at(attrs) do
    case fetch_value(attrs, :committed_at) do
      nil ->
        case fetch_value(attrs, :completed_at) do
          nil -> {:ok, nil}
          :null -> {:ok, nil}
          "" -> {:ok, nil}
          value when is_binary(value) -> {:ok, value}
          _ -> {:error, {:invalid_workflow_step_field, :committed_at}}
        end

      :null ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_binary(value) ->
        {:ok, value}

      _ ->
        {:error, {:invalid_workflow_step_field, :committed_at}}
    end
  end

  defp fetch_status(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      status when status in @statuses -> {:ok, status}
      status when is_atom(status) -> {:error, {:invalid_workflow_step_field, key}}
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
