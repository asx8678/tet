defmodule Tet.Subagent.Result do
  @moduledoc """
  Pure subagent result struct shared by core and runtime boundaries.

  Captures the output of a single subagent execution: the final output map,
  any artifacts produced, the execution status, and routing metadata for
  deterministic merge and artifact routing downstream.
  """

  alias Tet.Entity

  @statuses [:success, :failure, :partial]

  @enforce_keys [:id, :task_id, :session_id, :output, :status, :created_at]
  defstruct [
    :id,
    :task_id,
    :session_id,
    :output,
    :status,
    :created_at,
    artifacts: [],
    metadata: %{}
  ]

  @type status :: :success | :failure | :partial
  @type t :: %__MODULE__{
          id: String.t(),
          task_id: String.t(),
          session_id: String.t(),
          output: map(),
          artifacts: [map()],
          status: status(),
          metadata: map(),
          created_at: DateTime.t()
        }

  @doc "Returns accepted result statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds a validated subagent result from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :subagent_result),
         {:ok, task_id} <- Entity.fetch_required_binary(attrs, :task_id, :subagent_result),
         {:ok, session_id} <- Entity.fetch_required_binary(attrs, :session_id, :subagent_result),
         {:ok, output} <- Entity.fetch_map(attrs, :output, :subagent_result),
         {:ok, status} <- Entity.fetch_atom(attrs, :status, @statuses, :subagent_result),
         {:ok, created_at} <- Entity.fetch_required_datetime(attrs, :created_at, :subagent_result),
         {:ok, artifacts} <- Entity.fetch_list(attrs, :artifacts, :subagent_result),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :subagent_result) do
      {:ok,
       %__MODULE__{
         id: id,
         task_id: task_id,
         session_id: session_id,
         output: output,
         artifacts: artifacts,
         status: status,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_subagent_result}

  @doc "Converts a decoded map back to a subagent result."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Converts the subagent result to a map with stable string enums and timestamps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      id: result.id,
      task_id: result.task_id,
      session_id: result.session_id,
      output: result.output,
      artifacts: result.artifacts,
      status: Atom.to_string(result.status),
      created_at: Entity.datetime_to_map(result.created_at),
      metadata: result.metadata
    }
  end
end
