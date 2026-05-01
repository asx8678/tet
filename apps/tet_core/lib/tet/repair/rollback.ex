defmodule Tet.Repair.Rollback do
  @moduledoc """
  Repair rollback struct and lifecycle — BD-0062.

  When a repair fails, a rollback captures which patches were reverted,
  the reason for rollback, and the checkpoint to restore to. The error log
  remains open after a failed repair so the team can investigate further.

  ## Lifecycle

      :pending → :in_progress → :completed
                              → :failed

  This module is pure data and pure functions. It does not execute rollbacks,
  touch the filesystem, or persist events.
  """

  alias Tet.Entity

  @statuses [:pending, :in_progress, :completed, :failed]

  @enforce_keys [:id, :repair_id]
  defstruct [
    :id,
    :repair_id,
    :checkpoint_id,
    :reason,
    patches_reverted: [],
    status: :pending,
    error_log_kept_open: true,
    created_at: nil,
    completed_at: nil
  ]

  @type status :: :pending | :in_progress | :completed | :failed
  @type t :: %__MODULE__{
          id: binary(),
          repair_id: binary(),
          checkpoint_id: binary() | nil,
          reason: binary() | nil,
          patches_reverted: [binary()],
          status: status(),
          error_log_kept_open: boolean(),
          created_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @doc "Returns valid rollback statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Creates a validated rollback from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :rollback),
         {:ok, repair_id} <- Entity.fetch_required_binary(attrs, :repair_id, :rollback),
         {:ok, checkpoint_id} <- Entity.fetch_optional_binary(attrs, :checkpoint_id, :rollback),
         {:ok, reason} <- Entity.fetch_optional_binary(attrs, :reason, :rollback),
         {:ok, patches_reverted} <- fetch_string_list_or_default(attrs, :patches_reverted),
         {:ok, status} <- fetch_status(attrs, :status, :pending),
         {:ok, error_log_kept_open} <- fetch_boolean(attrs, :error_log_kept_open, true),
         {:ok, created_at} <- Entity.fetch_optional_datetime(attrs, :created_at, :rollback),
         {:ok, completed_at} <- Entity.fetch_optional_datetime(attrs, :completed_at, :rollback) do
      {:ok,
       %__MODULE__{
         id: id,
         repair_id: repair_id,
         checkpoint_id: checkpoint_id,
         reason: reason,
         patches_reverted: patches_reverted,
         status: status,
         error_log_kept_open: error_log_kept_open,
         created_at: created_at,
         completed_at: completed_at
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_rollback}

  @doc "Transitions a pending rollback to `:in_progress`."
  @spec begin(t()) :: {:ok, t()} | {:error, :not_pending}
  def begin(%__MODULE__{status: :pending} = rollback) do
    {:ok, %__MODULE__{rollback | status: :in_progress}}
  end

  def begin(%__MODULE__{}), do: {:error, :not_pending}

  @doc "Records a reverted patch ID on an in-progress rollback."
  @spec record_revert(t(), binary()) :: {:ok, t()} | {:error, :not_in_progress}
  def record_revert(%__MODULE__{status: :in_progress} = rollback, patch_id)
      when is_binary(patch_id) do
    {:ok, %__MODULE__{rollback | patches_reverted: rollback.patches_reverted ++ [patch_id]}}
  end

  def record_revert(%__MODULE__{}, _patch_id), do: {:error, :not_in_progress}

  @doc "Marks an in-progress rollback as completed."
  @spec complete(t()) :: {:ok, t()} | {:error, :not_in_progress}
  def complete(%__MODULE__{status: :in_progress} = rollback) do
    {:ok, %__MODULE__{rollback | status: :completed, completed_at: DateTime.utc_now()}}
  end

  def complete(%__MODULE__{}), do: {:error, :not_in_progress}

  @doc "Marks an in-progress rollback as failed with a reason."
  @spec fail(t(), binary()) :: {:ok, t()} | {:error, :not_in_progress}
  def fail(%__MODULE__{status: :in_progress} = rollback, reason) when is_binary(reason) do
    {:ok,
     %__MODULE__{rollback | status: :failed, reason: reason, completed_at: DateTime.utc_now()}}
  end

  def fail(%__MODULE__{}, _reason), do: {:error, :not_in_progress}

  @doc "Returns whether the error log should remain open after this rollback."
  @spec keep_error_log_open?(t()) :: boolean()
  def keep_error_log_open?(%__MODULE__{error_log_kept_open: kept_open}), do: kept_open

  @doc "Converts a rollback to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = rollback) do
    %{
      id: rollback.id,
      repair_id: rollback.repair_id,
      patches_reverted: rollback.patches_reverted,
      status: Atom.to_string(rollback.status),
      error_log_kept_open: rollback.error_log_kept_open
    }
    |> maybe_put(:checkpoint_id, rollback.checkpoint_id)
    |> maybe_put(:reason, rollback.reason)
    |> maybe_put(:created_at, Entity.datetime_to_map(rollback.created_at))
    |> maybe_put(:completed_at, Entity.datetime_to_map(rollback.completed_at))
  end

  @doc "Converts a decoded map back to a validated rollback."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Private helpers --

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_string_list_or_default(attrs, key) do
    case Entity.fetch_value(attrs, key, []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, {:invalid_rollback_field, key}}

      _ ->
        {:error, {:invalid_rollback_field, key}}
    end
  end

  defp fetch_boolean(attrs, key, default) do
    case Entity.fetch_value(attrs, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_rollback_field, key}}
    end
  end

  defp fetch_status(attrs, key, default) do
    case Entity.fetch_value(attrs, key, default) do
      status when status in @statuses -> {:ok, status}
      status when is_atom(status) -> {:error, {:invalid_rollback_field, key}}
      status when is_binary(status) -> parse_status(status)
      _ -> {:error, {:invalid_rollback_field, key}}
    end
  end

  defp parse_status(str) when is_binary(str) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_rollback_field, :status}}
      atom -> {:ok, atom}
    end
  end
end
