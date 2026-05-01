defmodule Tet.WorkflowStep do
  @moduledoc """
  Durable workflow-step journal entity from v0.3 §12.

  Step names use lowercase colon-separated grammar. Dots are for event types;
  steps with dots are where recovery code goes to get haunted. Failed steps store
  optional error data in `error` so recovery code has something better than vibes.
  """

  alias Tet.Entity

  @statuses [:started, :committed, :failed, :cancelled]
  @step_name_regex ~r/\A[a-z_]+(:[a-z0-9_]+)*\z/

  @enforce_keys [:id, :workflow_id, :step_name, :idempotency_key, :status, :started_at]
  defstruct [
    :id,
    :workflow_id,
    :step_name,
    :idempotency_key,
    :output,
    :error,
    :status,
    :started_at,
    :committed_at,
    input: %{},
    attempt: 1,
    metadata: %{}
  ]

  @type status :: :started | :committed | :failed | :cancelled
  @type t :: %__MODULE__{
          id: String.t(),
          workflow_id: String.t(),
          step_name: String.t(),
          idempotency_key: String.t(),
          input: term(),
          output: term() | nil,
          error: term() | nil,
          status: status(),
          started_at: DateTime.t(),
          committed_at: DateTime.t() | nil,
          attempt: pos_integer(),
          metadata: map()
        }

  @doc "Returns accepted workflow-step statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns true when the step name follows the v0.3 §12 grammar."
  @spec valid_step_name?(term()) :: boolean()
  def valid_step_name?(name) when is_binary(name), do: String.match?(name, @step_name_regex)
  def valid_step_name?(_name), do: false

  @doc "Builds a workflow step from atom- or string-keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :workflow_step),
         {:ok, workflow_id} <- Entity.fetch_required_binary(attrs, :workflow_id, :workflow_step),
         {:ok, step_name} <- fetch_step_name(attrs),
         {:ok, idempotency_key} <- Entity.fetch_sha256(attrs, :idempotency_key, :workflow_step),
         input <- Entity.fetch_value(attrs, :input, %{}),
         output <- Entity.fetch_value(attrs, :output),
         error <- Entity.fetch_value(attrs, :error),
         {:ok, status} <- Entity.fetch_atom(attrs, :status, @statuses, :workflow_step),
         {:ok, started_at} <- Entity.fetch_required_datetime(attrs, :started_at, :workflow_step),
         {:ok, committed_at} <-
           Entity.fetch_optional_datetime(attrs, :committed_at, :workflow_step),
         {:ok, attempt} <- Entity.fetch_positive_integer(attrs, :attempt, :workflow_step),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :workflow_step) do
      {:ok,
       %__MODULE__{
         id: id,
         workflow_id: workflow_id,
         step_name: step_name,
         idempotency_key: idempotency_key,
         input: input,
         output: output,
         error: error,
         status: status,
         started_at: started_at,
         committed_at: committed_at,
         attempt: attempt,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_workflow_step}

  @doc "Converts a decoded map back to a workflow step."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Converts the workflow step to a map with stable string enums and timestamps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = workflow_step) do
    %{
      id: workflow_step.id,
      workflow_id: workflow_step.workflow_id,
      step_name: workflow_step.step_name,
      idempotency_key: workflow_step.idempotency_key,
      input: workflow_step.input,
      output: workflow_step.output,
      error: workflow_step.error,
      status: Atom.to_string(workflow_step.status),
      started_at: Entity.datetime_to_map(workflow_step.started_at),
      committed_at: Entity.datetime_to_map(workflow_step.committed_at),
      attempt: workflow_step.attempt,
      metadata: workflow_step.metadata
    }
  end

  defp fetch_step_name(attrs) do
    with {:ok, step_name} <- Entity.fetch_required_binary(attrs, :step_name, :workflow_step),
         true <- valid_step_name?(step_name) do
      {:ok, step_name}
    else
      false -> Entity.value_error(:workflow_step, :step_name)
      {:error, reason} -> {:error, reason}
    end
  end
end
