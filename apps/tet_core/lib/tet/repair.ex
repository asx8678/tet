defmodule Tet.Repair do
  @moduledoc """
  Repair queue entry struct for self-healing workflows — BD-0034, BD-0057.

  A repair entry represents an actionable fix that the runtime can dequeue
  and apply. Repairs track the associated error, the proposed repair strategy,
  and execution lifecycle (pending → running → succeeded/failed/skipped).

  BD-0057 extends the schema with new strategies (`:fallback`, `:patch`,
  `:human`), refined statuses (`:running`, `:succeeded`), and dedicated
  `params`, `started_at`, and `completed_at` fields.

  This module is pure data and pure functions. It does not execute repairs,
  touch the filesystem, or persist events.
  """

  alias Tet.Entity

  @statuses [:pending, :running, :succeeded, :failed, :skipped]
  @terminal_statuses [:succeeded, :failed, :skipped]

  @enforce_keys [:id, :error_log_id, :strategy]
  defstruct [
    :id,
    :error_log_id,
    :session_id,
    :strategy,
    :params,
    :result,
    status: :pending,
    created_at: nil,
    started_at: nil,
    completed_at: nil,
    metadata: %{}
  ]

  @type status :: :pending | :running | :succeeded | :failed | :skipped
  @type strategy :: :retry | :fallback | :patch | :human
  @type t :: %__MODULE__{
          id: binary(),
          error_log_id: binary(),
          session_id: binary() | nil,
          strategy: strategy(),
          params: map() | nil,
          result: map() | nil,
          status: status(),
          created_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
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
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :repair),
         {:ok, error_log_id} <- Entity.fetch_required_binary(attrs, :error_log_id, :repair),
         {:ok, session_id} <- Entity.fetch_optional_binary(attrs, :session_id, :repair),
         {:ok, strategy} <- fetch_strategy(attrs),
         {:ok, params} <- fetch_optional_map(attrs, :params),
         {:ok, result} <- fetch_optional_map(attrs, :result),
         {:ok, status} <- fetch_status(attrs, :status, :pending),
         {:ok, created_at} <- Entity.fetch_optional_datetime(attrs, :created_at, :repair),
         {:ok, started_at} <- Entity.fetch_optional_datetime(attrs, :started_at, :repair),
         {:ok, completed_at} <- Entity.fetch_optional_datetime(attrs, :completed_at, :repair),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :repair) do
      {:ok,
       %__MODULE__{
         id: id,
         error_log_id: error_log_id,
         session_id: session_id,
         strategy: strategy,
         params: params,
         result: result,
         status: status,
         created_at: created_at,
         started_at: started_at,
         completed_at: completed_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_repair}

  @doc "Converts a repair entry to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = repair) do
    %{
      id: repair.id,
      error_log_id: repair.error_log_id,
      strategy: Entity.atom_to_map(repair.strategy),
      status: Atom.to_string(repair.status)
    }
    |> maybe_put(:session_id, repair.session_id)
    |> maybe_put(:params, repair.params)
    |> maybe_put(:result, repair.result)
    |> maybe_put(:created_at, Entity.datetime_to_map(repair.created_at))
    |> maybe_put(:started_at, Entity.datetime_to_map(repair.started_at))
    |> maybe_put(:completed_at, Entity.datetime_to_map(repair.completed_at))
    |> Map.put(:metadata, repair.metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Converts a decoded map back to a validated repair entry."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Private helpers --

  @allowed_strategies [:retry, :fallback, :patch, :human]

  defp fetch_strategy(attrs) do
    case Entity.fetch_value(attrs, :strategy) do
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
    case Entity.fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_repair_field, key}}
    end
  end

  defp fetch_status(attrs, key, default) do
    case Entity.fetch_value(attrs, key, default) do
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
end
