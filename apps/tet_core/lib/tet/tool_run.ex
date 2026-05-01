defmodule Tet.ToolRun do
  @moduledoc """
  Core persisted tool-run entity.

  Blocked tool calls are persisted too. If a tool was denied by policy, the
  timeline should remember that instead of pretending the gremlin never knocked.
  """

  alias Tet.Entity

  @directions [:read, :write]
  @statuses [:proposed, :blocked, :waiting_approval, :running, :success, :error]

  @enforce_keys [:id, :session_id, :tool_name, :read_or_write, :status]
  defstruct [
    :id,
    :session_id,
    :task_id,
    :tool_name,
    :read_or_write,
    :status,
    :block_reason,
    :started_at,
    :finished_at,
    args: %{},
    changed_files: [],
    metadata: %{}
  ]

  @type read_or_write :: :read | :write
  @type status :: :proposed | :blocked | :waiting_approval | :running | :success | :error
  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          task_id: String.t() | nil,
          tool_name: String.t(),
          read_or_write: read_or_write(),
          args: map(),
          status: status(),
          block_reason: atom() | nil,
          changed_files: [String.t()],
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          metadata: map()
        }

  @doc "Returns accepted read/write categories."
  @spec directions() :: [read_or_write()]
  def directions, do: @directions

  @doc "Returns accepted tool-run statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds a tool run from atom- or string-keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :tool_run),
         {:ok, session_id} <- Entity.fetch_required_binary(attrs, :session_id, :tool_run),
         {:ok, task_id} <- Entity.fetch_optional_binary(attrs, :task_id, :tool_run),
         {:ok, tool_name} <- Entity.fetch_required_binary(attrs, :tool_name, :tool_run),
         {:ok, read_or_write} <-
           Entity.fetch_atom(attrs, :read_or_write, @directions, :tool_run),
         {:ok, args} <- Entity.fetch_map(attrs, :args, :tool_run),
         {:ok, status} <- Entity.fetch_atom(attrs, :status, @statuses, :tool_run),
         {:ok, block_reason} <-
           Entity.fetch_optional_existing_atom(attrs, :block_reason, :tool_run),
         {:ok, changed_files} <- Entity.fetch_string_list(attrs, :changed_files, :tool_run),
         {:ok, started_at} <- Entity.fetch_optional_datetime(attrs, :started_at, :tool_run),
         {:ok, finished_at} <- Entity.fetch_optional_datetime(attrs, :finished_at, :tool_run),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :tool_run) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         task_id: task_id,
         tool_name: tool_name,
         read_or_write: read_or_write,
         args: args,
         status: status,
         block_reason: block_reason,
         changed_files: changed_files,
         started_at: started_at,
         finished_at: finished_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_tool_run}

  @doc "Converts a decoded map back to a tool run."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Converts the tool run to a map with stable string enums and timestamps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = tool_run) do
    %{
      id: tool_run.id,
      session_id: tool_run.session_id,
      task_id: tool_run.task_id,
      tool_name: tool_run.tool_name,
      read_or_write: Atom.to_string(tool_run.read_or_write),
      args: tool_run.args,
      status: Atom.to_string(tool_run.status),
      block_reason: Entity.atom_to_map(tool_run.block_reason),
      changed_files: tool_run.changed_files,
      started_at: Entity.datetime_to_map(tool_run.started_at),
      finished_at: Entity.datetime_to_map(tool_run.finished_at),
      metadata: tool_run.metadata
    }
  end
end
