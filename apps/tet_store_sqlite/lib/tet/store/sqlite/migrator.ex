defmodule Tet.Store.SQLite.Migrator do
  @moduledoc """
  Migration runner for the SQLite store adapter.

  Provides both the no-op `run!/0` (for application startup compatibility) and
  `run!/1` which accepts keyword opts including `:database` and performs real
  Ecto migrations using `Ecto.Migrator.run/4`.
  """

  alias Tet.Store.SQLite.{Connection, Repo}

  @doc false
  # Kept for backward compatibility — application startup calls run!/0.
  @spec run! :: :ok
  def run!, do: :ok

  @doc """
  Runs all pending migrations on the given database.

  Accepts keyword opts:
    * `:database` — path to the SQLite database file (required)

  Returns the list of applied migration versions.
  """
  @spec run!(keyword()) :: [integer()]
  def run!(opts) when is_list(opts) do
    database = Keyword.fetch!(opts, :database)
    repo_opts = Connection.repo_options(database: database)

    Connection.ensure_parent_dir!(database)

    {:ok, pid} = Repo.start_link(repo_opts)

    try do
      Connection.apply_and_verify!(Repo)
      Connection.ensure_auto_vacuum!(Repo)
      Ecto.Migrator.run(Repo, Connection.migrations_path(), :up, all: true, log: false)
    after
      Supervisor.stop(pid, :normal, 15_000)
    end
  end
end
