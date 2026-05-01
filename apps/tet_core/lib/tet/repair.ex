defmodule Tet.Repair do
  @moduledoc """
  Repair queue entry struct for self-healing workflows — BD-0034.

  A repair entry represents an actionable fix that the runtime can dequeue
  and apply. Repairs track the associated error, the proposed repair strategy,
  and execution lifecycle (pending → in_progress → completed/failed/skipped).

  This module is pure data and pure functions. It does not execute repairs,
  touch the filesystem, or persist events.
  """

  @statuses [:pending, :in_progress, :completed, :failed, :skipped]
  @terminal_statuses [:completed, :failed, :skipped]

  @enforce_keys [:id, :error_id, :strategy]
  defstruct [
    :id,
    :error_id,
    :session_id,
    :strategy,
    :description,
    :context,
    :result,
    status: :pending,
    created_at: nil,
    updated_at: nil,
    metadata: %{}
  ]

  @type status :: :pending | :in_progress | :completed | :failed | :skipped
  @type strategy :: :retry | :rollback | :skip | :manual | atom()
  @type t :: %__MODULE__{
          id: binary(),
          error_id: binary(),
          session_id: binary() | nil,
          strategy: strategy(),
          description: binary() | nil,
          context: map() | nil,
          result: map() | nil,
          status: status(),
          created_at: binary() | nil,
          updated_at: binary() | nil,
          metadata: map()
        }

  @doc "Returns valid repair statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns terminal repair statuses (no further transitions)."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Builds a validated repair entry from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, error_id} <- fetch_binary(attrs, :error_id),
         {:ok, session_id} <- fetch_optional_binary(attrs, :session_id),
         {:ok, strategy} <- fetch_strategy(attrs),
         {:ok, description} <- fetch_optional_binary(attrs, :description),
         {:ok, context} <- fetch_optional_map(attrs, :context),
         {:ok, result} <- fetch_optional_map(attrs, :result),
         {:ok, status} <- fetch_status(attrs, :status, :pending),
         {:ok, created_at} <- fetch_optional_binary(attrs, :created_at),
         {:ok, updated_at} <- fetch_optional_binary(attrs, :updated_at),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         id: id,
         error_id: error_id,
         session_id: session_id,
         strategy: strategy,
         description: description,
         context: context,
         result: result,
         status: status,
         created_at: created_at,
         updated_at: updated_at,
         metadata: metadata
       }}
    end
  end

  @doc "Converts a repair entry to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = repair) do
    %{
      id: repair.id,
      error_id: repair.error_id,
      strategy: atom_to_string(repair.strategy),
      status: Atom.to_string(repair.status)
    }
    |> maybe_put(:session_id, repair.session_id)
    |> maybe_put(:description, repair.description)
    |> maybe_put(:context, repair.context)
    |> maybe_put(:result, repair.result)
    |> maybe_put(:created_at, repair.created_at)
    |> maybe_put(:updated_at, repair.updated_at)
    |> Map.put(:metadata, repair.metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Converts a decoded map back to a validated repair entry."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Private helpers --

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_repair_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_repair_field, key}}
    end
  end

  @allowed_strategies [:retry, :rollback, :skip, :manual, :recreate, :purge, :notify]

  defp fetch_strategy(attrs) do
    case fetch_value(attrs, :strategy) do
      strategy when strategy in @allowed_strategies ->
        {:ok, strategy}

      strategy when is_atom(strategy) ->
        {:error, {:invalid_repair_field, :strategy}}

      strategy when is_binary(strategy) and strategy != "" ->
        case Enum.find(@allowed_strategies, &(Atom.to_string(&1) == strategy)) do
          nil -> {:error, {:invalid_repair_field, :strategy}}
          atom -> {:ok, atom}
        end

      _ ->
        {:error, {:invalid_repair_field, :strategy}}
    end
  end

  defp fetch_optional_map(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_repair_field, key}}
    end
  end

  defp fetch_status(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      status when status in @statuses -> {:ok, status}
      status when is_atom(status) -> {:error, {:invalid_repair_field, key}}
      status when is_binary(status) -> parse_status(status)
      _ -> {:error, {:invalid_repair_field, key}}
    end
  end

  defp parse_status(str) when is_binary(str) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_repair_field, :status}}
      atom -> {:ok, atom}
    end
  end

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      nil -> {:ok, default}
      :null -> {:ok, default}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_repair_field, key}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp atom_to_string(nil), do: nil
  defp atom_to_string(value), do: Atom.to_string(value)
end
