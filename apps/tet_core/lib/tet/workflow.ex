defmodule Tet.Workflow do
  @moduledoc """
  Durable workflow entity from v0.3 §12.

  A workflow is the persisted execution record for an agent loop. Runtime
  executors may cache state, but recovery truth lives here and in
  `Tet.WorkflowStep` rows.
  """

  alias Tet.Entity

  @statuses [:running, :paused_for_approval, :completed, :failed, :cancelled]

  @enforce_keys [:id, :session_id, :status, :created_at, :updated_at]
  defstruct [:id, :session_id, :task_id, :status, :created_at, :updated_at, metadata: %{}]

  @type status :: :running | :paused_for_approval | :completed | :failed | :cancelled
  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          task_id: String.t() | nil,
          status: status(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          metadata: map()
        }

  @doc "Returns accepted workflow statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds a workflow from atom- or string-keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :workflow),
         {:ok, session_id} <- Entity.fetch_required_binary(attrs, :session_id, :workflow),
         {:ok, task_id} <- Entity.fetch_optional_binary(attrs, :task_id, :workflow),
         {:ok, status} <- Entity.fetch_atom(attrs, :status, @statuses, :workflow),
         {:ok, created_at} <- Entity.fetch_required_datetime(attrs, :created_at, :workflow),
         {:ok, updated_at} <- Entity.fetch_required_datetime(attrs, :updated_at, :workflow),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :workflow) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         task_id: task_id,
         status: status,
         created_at: created_at,
         updated_at: updated_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_workflow}

  @doc "Converts a decoded map back to a workflow."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Converts the workflow to a map with stable string enums and timestamps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = workflow) do
    %{
      id: workflow.id,
      session_id: workflow.session_id,
      task_id: workflow.task_id,
      status: Atom.to_string(workflow.status),
      created_at: Entity.datetime_to_map(workflow.created_at),
      updated_at: Entity.datetime_to_map(workflow.updated_at),
      metadata: workflow.metadata
    }
  end
end
