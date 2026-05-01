defmodule Tet.Store.SQLite.Migrator do
  @moduledoc """
  No-op migrator for the JSONL-based store adapter.

  The JSONL adapter has no schema or migrations — all data is stored as
  append-only JSON lines. This migrator exists to satisfy the application
  startup call. When the adapter is upgraded to true SQLite with Ecto,
  real migrations will live here.
  """

  @spec run! :: :ok
  def run!, do: :ok
end
