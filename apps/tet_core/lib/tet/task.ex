defmodule Tet.Task do
  @moduledoc """
  Core task entity for persisted agent work inside a session.

  V1 allows one active task per session; stores enforce that as a persistent
  invariant rather than trusting a process mailbox and a prayer.
  """

  alias Tet.Entity

  @statuses [:active, :complete, :cancelled]

  @enforce_keys [:id, :session_id, :title, :status, :created_at, :updated_at]
  defstruct [:id, :session_id, :title, :status, :created_at, :updated_at, metadata: %{}]

  @type status :: :active | :complete | :cancelled
  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          title: String.t(),
          status: status(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          metadata: map()
        }

  @doc "Returns accepted task statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds a task from atom- or string-keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :task),
         {:ok, session_id} <- Entity.fetch_required_binary(attrs, :session_id, :task),
         {:ok, title} <- Entity.fetch_required_binary(attrs, :title, :task),
         {:ok, status} <- Entity.fetch_atom(attrs, :status, @statuses, :task),
         {:ok, created_at} <- Entity.fetch_required_datetime(attrs, :created_at, :task),
         {:ok, updated_at} <- Entity.fetch_required_datetime(attrs, :updated_at, :task),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :task) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         title: title,
         status: status,
         created_at: created_at,
         updated_at: updated_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_task}

  @doc "Converts a decoded map back to a task."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Converts the task to a map with stable string enums and timestamps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = task) do
    %{
      id: task.id,
      session_id: task.session_id,
      title: task.title,
      status: Atom.to_string(task.status),
      created_at: Entity.datetime_to_map(task.created_at),
      updated_at: Entity.datetime_to_map(task.updated_at),
      metadata: task.metadata
    }
  end
end
