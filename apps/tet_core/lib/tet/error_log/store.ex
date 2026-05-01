defmodule Tet.ErrorLog.Store do
  @moduledoc """
  Error log and repair queue persistence layer — BD-0057.

  Wraps a `Tet.Store` adapter to provide focused error_log and repair
  operations. Callers pass the store module (defaulting to the configured
  `:tet, :store` adapter) so the adapter seam remains explicit and testable.

  This module is the runtime entry point for error tracking and self-healing.
  It does **not** define its own process or storage — it delegates everything
  to the underlying `Tet.Store` behaviour implementation.
  """

  @doc """
  Logs an error entry via the given store adapter.

  Returns `{:ok, Tet.ErrorLog.t()}` on success.
  """
  @spec log_error(module(), Tet.ErrorLog.t(), keyword()) ::
          {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def log_error(store \\ default_store(), attrs, opts \\ []) when is_map(attrs) do
    store.log_error(attrs, opts)
  end

  @doc """
  Lists error log entries for a session.
  """
  @spec list_errors(module(), String.t(), keyword()) ::
          {:ok, [Tet.ErrorLog.t()]} | {:error, term()}
  def list_errors(store \\ default_store(), session_id, opts \\ []) when is_binary(session_id) do
    store.list_errors(session_id, opts)
  end

  @doc """
  Fetches a single error log entry by id.
  """
  @spec get_error(module(), String.t(), keyword()) ::
          {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def get_error(store \\ default_store(), error_id, opts \\ []) when is_binary(error_id) do
    store.get_error(error_id, opts)
  end

  @doc """
  Resolves an error log entry, setting its status to `:resolved`.
  """
  @spec resolve_error(module(), String.t(), keyword()) ::
          {:ok, Tet.ErrorLog.t()} | {:error, term()}
  def resolve_error(store \\ default_store(), error_id, opts \\ []) when is_binary(error_id) do
    store.resolve_error(error_id, opts)
  end

  @doc """
  Enqueues a repair entry for an error.
  """
  @spec enqueue_repair(module(), Tet.Repair.t(), keyword()) ::
          {:ok, Tet.Repair.t()} | {:error, term()}
  def enqueue_repair(store \\ default_store(), attrs, opts \\ []) when is_map(attrs) do
    store.enqueue_repair(attrs, opts)
  end

  @doc """
  Dequeues the next pending repair entry and marks it `:running`.
  """
  @spec dequeue_repair(module(), keyword()) ::
          {:ok, Tet.Repair.t() | nil} | {:error, term()}
  def dequeue_repair(store \\ default_store(), opts \\ []) do
    store.dequeue_repair(opts)
  end

  @doc """
  Updates a repair entry (status, result, etc.).
  """
  @spec update_repair(module(), String.t(), map(), keyword()) ::
          {:ok, Tet.Repair.t()} | {:error, term()}
  def update_repair(store \\ default_store(), repair_id, attrs, opts \\ [])
      when is_binary(repair_id) and is_map(attrs) do
    store.update_repair(repair_id, attrs, opts)
  end

  @doc """
  Lists repair entries, optionally filtered by session_id or status in opts.
  """
  @spec list_repairs(module(), keyword()) ::
          {:ok, [Tet.Repair.t()]} | {:error, term()}
  def list_repairs(store \\ default_store(), opts \\ []) do
    store.list_repairs(opts)
  end

  # -- Default store adapter --

  defp default_store do
    Application.get_env(:tet, :store, Tet.Store.Memory)
  end
end
