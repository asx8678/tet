defmodule Tet.Store.Helpers do
  @moduledoc """
  Shared adapter helper functions for Tet.Store implementations.

  Extracted from individual adapters to ensure consistent behaviour
  across Memory and SQLite (DRY). Both adapters delegate to these
  helpers so contract differences don't creep in.
  """

  # Fields that are safe to update on a Repair entry.
  # Identity and correlation fields (id, error_log_id, session_id,
  # strategy, created_at) are immutable after creation.
  @repair_mutable_fields [:status, :params, :result, :started_at, :completed_at, :metadata]

  @doc """
  Strips repair update attrs to only the explicitly mutable fields.

  Prevents callers from mutating identity/correlation columns
  (`id`, `error_log_id`, `session_id`, `strategy`, `created_at`)
  through `update_repair/3`.
  """
  @spec sanitize_repair_update_attrs(map()) :: map()
  def sanitize_repair_update_attrs(attrs) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> Map.take(Enum.map(@repair_mutable_fields, &Atom.to_string/1))
  end

  @doc """
  Merges repair update attrs into an existing repair, validating the result.

  Returns `{:ok, Tet.Repair.t()}` on success, `{:error, reason}` on failure.
  **Never raises** — safe to call inside GenServer/Agent callbacks.
  """
  @spec merge_repair_attrs(Tet.Repair.t(), map()) ::
          {:ok, Tet.Repair.t()} | {:error, term()}
  def merge_repair_attrs(%Tet.Repair{} = repair, attrs) when is_map(attrs) do
    sanitized = sanitize_repair_update_attrs(attrs)

    repair
    |> Tet.Repair.to_map()
    |> stringify_keys()
    |> Map.merge(sanitized)
    |> Tet.Repair.new()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Ensures `created_at` is present in attrs, defaulting to `DateTime.utc_now/0`.

  Checks both atom and string key variants.
  """
  @spec ensure_created_at(map()) :: map()
  def ensure_created_at(attrs) when is_map(attrs) do
    has_created_at? =
      Map.has_key?(attrs, :created_at) or Map.has_key?(attrs, "created_at")

    if has_created_at?, do: attrs, else: Map.put(attrs, :created_at, DateTime.utc_now())
  end

  @doc """
  Converts all atom keys in a map to string keys.

  Non-atom keys are left as-is.
  """
  @spec stringify_keys(map()) :: map()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, val} when is_atom(key) -> {Atom.to_string(key), val}
      {key, val} -> {key, val}
    end)
  end

  @doc """
  Filters repairs by session_id (optional).
  """
  @spec maybe_filter_by_session([Tet.Repair.t()], String.t() | nil) :: [Tet.Repair.t()]
  def maybe_filter_by_session(repairs, nil), do: repairs

  def maybe_filter_by_session(repairs, session_id) when is_binary(session_id) do
    Enum.filter(repairs, &(&1.session_id == session_id))
  end

  @doc """
  Filters repairs by status (optional).
  """
  @spec maybe_filter_by_status([Tet.Repair.t()], atom() | nil) :: [Tet.Repair.t()]
  def maybe_filter_by_status(repairs, nil), do: repairs

  def maybe_filter_by_status(repairs, status) when is_atom(status) do
    Enum.filter(repairs, &(&1.status == status))
  end
end
