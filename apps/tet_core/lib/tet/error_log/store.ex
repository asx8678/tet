defmodule Tet.ErrorLog.Store do
  @moduledoc """
  Error log and repair queue persistence layer — BD-0057.

  Wraps a `Tet.Store` adapter to provide focused error_log and repair
  operations. Callers pass the store module (defaulting to the configured
  `:tet_core, :store_adapter`) so the adapter seam remains explicit and
  testable without crossing the core↔runtime architecture boundary.

  This module is the runtime entry point for error tracking and self-healing.
  It does **not** define its own process or storage — it delegates everything
  to the underlying `Tet.Store` behaviour implementation.
  """

  @trigger_classes [:exception, :crash, :compile_failure, :smoke_failure, :remote_failure]

  @doc """
  Returns the recognised trigger classes that `capture_failure/3` accepts.

  Each trigger class creates a correlated Error Log + Repair Queue record pair.
  """
  @spec trigger_classes() :: [atom()]
  def trigger_classes, do: @trigger_classes

  @doc """
  Captures a failure by atomically creating both an error log entry and
  a repair queue entry with proper correlation.

  `kind` must be one of the trigger classes (see `trigger_classes/0`).
  `attrs` supplies shared fields; `repair_opts` may include `:strategy`,
  `:params`, and `:metadata` for the repair entry.

  Returns `{:ok, {Tet.ErrorLog.t(), Tet.Repair.t()}}` on success,
  `{:error, reason}` on failure.

  ## Example

      {:ok, {error, repair}} =
        Tet.ErrorLog.Store.capture_failure(
          :exception,
          %{
            session_id: "ses_001",
            message: "Division by zero",
            stacktrace: "** (ArithmeticError)..."
          },
          strategy: :retry
        )
  """
  @spec capture_failure(atom(), map(), keyword()) ::
          {:ok, {Tet.ErrorLog.t(), Tet.Repair.t()}} | {:error, term()}
  def capture_failure(kind, attrs, repair_opts \\ [])
      when is_atom(kind) and is_map(attrs) and is_list(repair_opts) do
    with :ok <- validate_trigger_class(kind),
         attrs = ensure_error_id(attrs),
         {:ok, error_entry} <- log_error(Map.put(attrs, :kind, kind)),
         repair_attrs <- build_repair_attrs(error_entry, repair_opts),
         {:ok, repair} <- enqueue_repair(repair_attrs) do
      {:ok, {error_entry, repair}}
    end
  end

  @doc """
  Captures a failure using an explicit store adapter.

  Same as `capture_failure/3` but takes an explicit store module
  instead of using the configured default.
  """
  @spec capture_failure(atom(), module(), map(), keyword()) ::
          {:ok, {Tet.ErrorLog.t(), Tet.Repair.t()}} | {:error, term()}
  def capture_failure(kind, store, attrs, repair_opts)
      when is_atom(kind) and is_atom(store) and is_map(attrs) and is_list(repair_opts) do
    with :ok <- validate_trigger_class(kind),
         attrs = ensure_error_id(attrs),
         {:ok, error_entry} <- log_error(store, Map.put(attrs, :kind, kind), []),
         repair_attrs <- build_repair_attrs(error_entry, repair_opts),
         {:ok, repair} <- enqueue_repair(store, repair_attrs, []) do
      {:ok, {error_entry, repair}}
    end
  end

  @doc """
  Logs an error entry via the given store adapter.

  Returns `{:ok, Tet.ErrorLog.t()}` on success.
  """
  @spec log_error(map(), keyword()) :: {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def log_error(attrs) when is_map(attrs), do: log_error(default_store(), attrs, [])

  @spec log_error(map(), keyword()) :: {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def log_error(attrs, opts) when is_map(attrs) and is_list(opts),
    do: log_error(default_store(), attrs, opts)

  @spec log_error(module(), map()) :: {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def log_error(store, attrs) when is_atom(store) and is_map(attrs),
    do: log_error(store, attrs, [])

  @spec log_error(module(), map(), keyword()) :: {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def log_error(store, attrs, opts)
      when is_atom(store) and is_map(attrs) and is_list(opts) do
    store.log_error(attrs, opts)
  end

  @doc """
  Lists error log entries for a session.
  """
  @spec list_errors(String.t(), keyword()) :: {:ok, [Tet.ErrorLog.t()]} | {:error, term()}
  def list_errors(session_id) when is_binary(session_id),
    do: list_errors(default_store(), session_id, [])

  @spec list_errors(String.t(), keyword()) :: {:ok, [Tet.ErrorLog.t()]} | {:error, term()}
  def list_errors(session_id, opts) when is_binary(session_id) and is_list(opts),
    do: list_errors(default_store(), session_id, opts)

  @spec list_errors(module(), String.t()) :: {:ok, [Tet.ErrorLog.t()]} | {:error, term()}
  def list_errors(store, session_id) when is_atom(store) and is_binary(session_id),
    do: list_errors(store, session_id, [])

  @spec list_errors(module(), String.t(), keyword()) ::
          {:ok, [Tet.ErrorLog.t()]} | {:error, term()}
  def list_errors(store, session_id, opts)
      when is_atom(store) and is_binary(session_id) and is_list(opts) do
    store.list_errors(session_id, opts)
  end

  @doc """
  Fetches a single error log entry by id.
  """
  @spec get_error(String.t(), keyword()) :: {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def get_error(error_id) when is_binary(error_id), do: get_error(default_store(), error_id, [])

  @spec get_error(String.t(), keyword()) :: {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def get_error(error_id, opts) when is_binary(error_id) and is_list(opts),
    do: get_error(default_store(), error_id, opts)

  @spec get_error(module(), String.t()) :: {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def get_error(store, error_id) when is_atom(store) and is_binary(error_id),
    do: get_error(store, error_id, [])

  @spec get_error(module(), String.t(), keyword()) ::
          {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def get_error(store, error_id, opts)
      when is_atom(store) and is_binary(error_id) and is_list(opts) do
    store.get_error(error_id, opts)
  end

  @doc """
  Resolves an error log entry, setting its status to `:resolved`.
  """
  @spec resolve_error(String.t(), keyword()) ::
          {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def resolve_error(error_id) when is_binary(error_id),
    do: resolve_error(default_store(), error_id, [])

  @spec resolve_error(String.t(), keyword()) ::
          {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def resolve_error(error_id, opts) when is_binary(error_id) and is_list(opts),
    do: resolve_error(default_store(), error_id, opts)

  @spec resolve_error(module(), String.t()) ::
          {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def resolve_error(store, error_id) when is_atom(store) and is_binary(error_id),
    do: resolve_error(store, error_id, [])

  @spec resolve_error(module(), String.t(), keyword()) ::
          {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def resolve_error(store, error_id, opts)
      when is_atom(store) and is_binary(error_id) and is_list(opts) do
    store.resolve_error(error_id, opts)
  end

  @doc """
  Enqueues a repair entry for an error.
  """
  @spec enqueue_repair(map(), keyword()) :: {:ok, Tet.Repair.t()} | {:error, term()}
  def enqueue_repair(attrs) when is_map(attrs), do: enqueue_repair(default_store(), attrs, [])

  @spec enqueue_repair(map(), keyword()) :: {:ok, Tet.Repair.t()} | {:error, term()}
  def enqueue_repair(attrs, opts) when is_map(attrs) and is_list(opts),
    do: enqueue_repair(default_store(), attrs, opts)

  @spec enqueue_repair(module(), map()) :: {:ok, Tet.Repair.t()} | {:error, term()}
  def enqueue_repair(store, attrs) when is_atom(store) and is_map(attrs),
    do: enqueue_repair(store, attrs, [])

  @spec enqueue_repair(module(), map(), keyword()) ::
          {:ok, Tet.Repair.t()} | {:error, term()}
  def enqueue_repair(store, attrs, opts)
      when is_atom(store) and is_map(attrs) and is_list(opts) do
    store.enqueue_repair(attrs, opts)
  end

  @doc """
  Dequeues the next pending repair entry and marks it `:running`.
  """
  @spec dequeue_repair(keyword()) :: {:ok, Tet.Repair.t() | nil} | {:error, term()}
  def dequeue_repair(), do: dequeue_repair(default_store(), [])

  @spec dequeue_repair(keyword()) :: {:ok, Tet.Repair.t() | nil} | {:error, term()}
  def dequeue_repair(opts) when is_list(opts), do: dequeue_repair(default_store(), opts)

  @spec dequeue_repair(module()) :: {:ok, Tet.Repair.t() | nil} | {:error, term()}
  def dequeue_repair(store) when is_atom(store), do: dequeue_repair(store, [])

  @spec dequeue_repair(module(), keyword()) ::
          {:ok, Tet.Repair.t() | nil} | {:error, term()}
  def dequeue_repair(store, opts) when is_atom(store) and is_list(opts) do
    store.dequeue_repair(opts)
  end

  @doc """
  Updates a repair entry (status, result, etc.).

  Only mutable fields are accepted: `status`, `params`, `result`,
  `started_at`, `completed_at`, `metadata`. Identity and correlation
  fields (`id`, `error_log_id`, `session_id`, `strategy`, `created_at`)
  are immutable after creation.
  """
  @spec update_repair(String.t(), map(), keyword()) ::
          {:ok, Tet.Repair.t()} | {:error, term()}
  def update_repair(repair_id, attrs) when is_binary(repair_id) and is_map(attrs),
    do: update_repair(default_store(), repair_id, attrs, [])

  @spec update_repair(String.t(), map(), keyword()) ::
          {:ok, Tet.Repair.t()} | {:error, term()}
  def update_repair(repair_id, attrs, opts)
      when is_binary(repair_id) and is_map(attrs) and is_list(opts),
      do: update_repair(default_store(), repair_id, attrs, opts)

  @spec update_repair(module(), String.t(), map()) ::
          {:ok, Tet.Repair.t()} | {:error, term()}
  def update_repair(store, repair_id, attrs)
      when is_atom(store) and is_binary(repair_id) and is_map(attrs),
      do: update_repair(store, repair_id, attrs, [])

  @spec update_repair(module(), String.t(), map(), keyword()) ::
          {:ok, Tet.Repair.t()} | {:error, term()}
  def update_repair(store, repair_id, attrs, opts)
      when is_atom(store) and is_binary(repair_id) and is_map(attrs) and is_list(opts) do
    store.update_repair(repair_id, attrs, opts)
  end

  @doc """
  Lists repair entries, optionally filtered by session_id or status in opts.
  """
  @spec list_repairs(keyword()) :: {:ok, [Tet.Repair.t()]} | {:error, term()}
  def list_repairs(), do: list_repairs(default_store(), [])

  @spec list_repairs(keyword()) :: {:ok, [Tet.Repair.t()]} | {:error, term()}
  def list_repairs(opts) when is_list(opts), do: list_repairs(default_store(), opts)

  @spec list_repairs(module()) :: {:ok, [Tet.Repair.t()]} | {:error, term()}
  def list_repairs(store) when is_atom(store), do: list_repairs(store, [])

  @spec list_repairs(module(), keyword()) :: {:ok, [Tet.Repair.t()]} | {:error, term()}
  def list_repairs(store, opts) when is_atom(store) and is_list(opts) do
    store.list_repairs(opts)
  end

  # -- Default store adapter (core-owned config, NOT :tet_runtime) --

  defp default_store do
    Application.get_env(:tet_core, :store_adapter, Tet.Store.Memory)
  end

  # -- capture_failure helpers --

  defp validate_trigger_class(kind) when kind in @trigger_classes, do: :ok

  defp validate_trigger_class(kind),
    do: {:error, {:invalid_trigger_class, kind}}

  defp ensure_error_id(attrs) do
    if Map.has_key?(attrs, :id) or Map.has_key?(attrs, "id") do
      attrs
    else
      Map.put(attrs, :id, generate_error_id())
    end
  end

  defp build_repair_attrs(error_entry, repair_opts) do
    strategy = Keyword.get(repair_opts, :strategy, default_strategy(error_entry.kind))
    params = Keyword.get(repair_opts, :params)
    metadata = Keyword.get(repair_opts, :metadata, %{})

    %{
      id: generate_repair_id(error_entry.id),
      error_log_id: error_entry.id,
      session_id: error_entry.session_id,
      strategy: strategy,
      params: params,
      metadata: metadata
    }
  end

  # Default strategy mapping by trigger class
  defp default_strategy(:exception), do: :retry
  defp default_strategy(:crash), do: :retry
  defp default_strategy(:compile_failure), do: :patch
  defp default_strategy(:smoke_failure), do: :patch
  defp default_strategy(:remote_failure), do: :fallback

  defp generate_repair_id(error_log_id) do
    "rep_#{error_log_id}"
  end

  defp generate_error_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower) |> then(&"err_#{&1}")
  end
end
