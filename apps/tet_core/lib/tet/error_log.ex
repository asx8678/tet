defmodule Tet.ErrorLog do
  @moduledoc """
  Error log entry struct for persistent error tracking — BD-0034.

  Errors are persisted to the store for audit, diagnosis, and repair
  coordination (§04, §12). Each entry records the error kind, a human-readable
  message, optional context metadata, and a resolution status.

  This module is pure data and pure functions. It does not dispatch tools,
  touch the filesystem, or persist events.
  """

  @statuses [:open, :resolved]

  @enforce_keys [:id, :session_id, :kind, :message]
  defstruct [
    :id,
    :session_id,
    :task_id,
    :kind,
    :message,
    :context,
    :resolved_at,
    status: :open,
    created_at: nil,
    metadata: %{}
  ]

  @type status :: :open | :resolved
  @type kind :: atom()
  @type t :: %__MODULE__{
          id: binary(),
          session_id: binary(),
          task_id: binary() | nil,
          kind: kind(),
          message: binary(),
          context: map() | nil,
          resolved_at: binary() | nil,
          status: status(),
          created_at: binary() | nil,
          metadata: map()
        }

  @doc "Returns valid error statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Builds a validated error log entry from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, session_id} <- fetch_binary(attrs, :session_id),
         {:ok, task_id} <- fetch_optional_binary(attrs, :task_id),
         {:ok, kind} <- fetch_kind(attrs),
         {:ok, message} <- fetch_binary(attrs, :message),
         {:ok, context} <- fetch_optional_map(attrs, :context),
         {:ok, status} <- fetch_status(attrs, :status, :open),
         {:ok, resolved_at} <- fetch_optional_binary(attrs, :resolved_at),
         {:ok, created_at} <- fetch_optional_binary(attrs, :created_at),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         task_id: task_id,
         kind: kind,
         message: message,
         context: context,
         status: status,
         resolved_at: resolved_at,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  @doc "Resolves an open error, setting status to :resolved and recording the time."
  @spec resolve(t(), binary()) :: t()
  def resolve(%__MODULE__{} = error, resolved_at) when is_binary(resolved_at) do
    %__MODULE__{error | status: :resolved, resolved_at: resolved_at}
  end

  @doc "Converts an error log entry to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      id: error.id,
      session_id: error.session_id,
      kind: atom_to_string(error.kind),
      message: error.message,
      status: Atom.to_string(error.status)
    }
    |> maybe_put(:task_id, error.task_id)
    |> maybe_put(:context, error.context)
    |> maybe_put(:resolved_at, error.resolved_at)
    |> maybe_put(:created_at, error.created_at)
    |> Map.put(:metadata, error.metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Converts a decoded map back to a validated error log entry."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Private helpers --

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_error_log_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_error_log_field, key}}
    end
  end

  @allowed_kinds [
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
    allowed = @allowed_kinds

    case fetch_value(attrs, :kind) do
      kind when is_atom(kind) and not is_nil(kind) ->
        {:ok, kind}

      kind when is_binary(kind) and kind != "" ->
        atom = String.to_existing_atom(kind)
        if atom in allowed, do: {:ok, atom}, else: {:error, {:invalid_error_log_field, :kind}}

      _ ->
        {:error, {:invalid_error_log_field, :kind}}
    end
  end

  defp fetch_optional_map(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_error_log_field, key}}
    end
  end

  defp fetch_status(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      status when status in @statuses -> {:ok, status}
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

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      nil -> {:ok, default}
      :null -> {:ok, default}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_error_log_field, key}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp atom_to_string(nil), do: nil
  defp atom_to_string(value), do: Atom.to_string(value)
end
