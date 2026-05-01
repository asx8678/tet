defmodule Tet.ErrorLog do
  @moduledoc """
  Error log entry struct for persistent error tracking — BD-0034, BD-0057.

  Errors are persisted to the store for audit, diagnosis, and repair
  coordination (§04, §12). Each entry records the error kind, a human-readable
  message, optional stacktrace and context metadata, and a resolution status.

  BD-0057 extends the schema with all trigger classes (`:exception`, `:crash`,
  `:compile_failure`, `:smoke_failure`, `:remote_failure`), a `:dismissed`
  status, and an optional `stacktrace` field for runtime diagnostics.

  This module is pure data and pure functions. It does not dispatch tools,
  touch the filesystem, or persist events.
  """

  alias Tet.Entity

  @statuses [:open, :resolved, :dismissed]

  @enforce_keys [:id, :session_id, :kind, :message]
  defstruct [
    :id,
    :session_id,
    :task_id,
    :kind,
    :message,
    :stacktrace,
    :context,
    :resolved_at,
    status: :open,
    created_at: nil,
    metadata: %{}
  ]

  @type status :: :open | :resolved | :dismissed
  @type kind :: atom()
  @type t :: %__MODULE__{
          id: binary(),
          session_id: binary(),
          task_id: binary() | nil,
          kind: kind(),
          message: binary(),
          stacktrace: binary() | nil,
          context: map() | nil,
          resolved_at: DateTime.t() | nil,
          status: status(),
          created_at: DateTime.t() | nil,
          metadata: map()
        }

  @doc "Returns valid error statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds a validated error log entry from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :error_log),
         {:ok, session_id} <- Entity.fetch_required_binary(attrs, :session_id, :error_log),
         {:ok, task_id} <- Entity.fetch_optional_binary(attrs, :task_id, :error_log),
         {:ok, kind} <- fetch_kind(attrs),
         {:ok, message} <- Entity.fetch_required_binary(attrs, :message, :error_log),
         {:ok, stacktrace} <- Entity.fetch_optional_binary(attrs, :stacktrace, :error_log),
         {:ok, context} <- fetch_optional_map(attrs, :context),
         {:ok, status} <- fetch_status(attrs, :status, :open),
         {:ok, resolved_at} <- Entity.fetch_optional_datetime(attrs, :resolved_at, :error_log),
         {:ok, created_at} <- Entity.fetch_optional_datetime(attrs, :created_at, :error_log),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :error_log) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         task_id: task_id,
         kind: kind,
         message: message,
         stacktrace: stacktrace,
         context: context,
         status: status,
         resolved_at: resolved_at,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_error_log}

  @doc "Resolves an open error, setting status to :resolved and recording the time."
  @spec resolve(t(), DateTime.t()) :: t()
  def resolve(%__MODULE__{} = error, %DateTime{} = resolved_at) do
    %__MODULE__{error | status: :resolved, resolved_at: resolved_at}
  end

  @doc "Converts an error log entry to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      id: error.id,
      session_id: error.session_id,
      kind: Entity.atom_to_map(error.kind),
      message: error.message,
      status: Atom.to_string(error.status)
    }
    |> maybe_put(:task_id, error.task_id)
    |> maybe_put(:stacktrace, error.stacktrace)
    |> maybe_put(:context, error.context)
    |> maybe_put(:resolved_at, Entity.datetime_to_map(error.resolved_at))
    |> maybe_put(:created_at, Entity.datetime_to_map(error.created_at))
    |> Map.put(:metadata, error.metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Converts a decoded map back to a validated error log entry."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Private helpers --

  @allowed_kinds [
    # Runtime trigger classes (BD-0057)
    :exception,
    :crash,
    :compile_failure,
    :smoke_failure,
    :remote_failure,
    # Existing error kinds (BD-0034)
    :provider_error,
    :tool_error,
    :verification_error,
    :auth_error,
    :rate_limit_error,
    :timeout_error,
    :parse_error,
    :policy_error,
    :store_error,
    :unknown_error
  ]

  defp fetch_kind(attrs) do
    case Entity.fetch_value(attrs, :kind) do
      kind when kind in @allowed_kinds ->
        {:ok, kind}

      kind when is_atom(kind) ->
        {:error, {:invalid_error_log_field, :kind}}

      kind when is_binary(kind) and kind != "" ->
        case Enum.find(@allowed_kinds, &(Atom.to_string(&1) == kind)) do
          nil -> {:error, {:invalid_error_log_field, :kind}}
          atom -> {:ok, atom}
        end

      _ ->
        {:error, {:invalid_error_log_field, :kind}}
    end
  end

  defp fetch_optional_map(attrs, key) do
    case Entity.fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_error_log_field, key}}
    end
  end

  defp fetch_status(attrs, key, default) do
    case Entity.fetch_value(attrs, key, default) do
      status when status in @statuses -> {:ok, status}
      status when is_atom(status) -> {:error, {:invalid_error_log_field, key}}
      status when is_binary(status) -> parse_status(status)
      _ -> {:error, {:invalid_error_log_field, key}}
    end
  end

  defp parse_status(str) when is_binary(str) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_error_log_field, :status}}
      atom -> {:ok, atom}
    end
  end
end
