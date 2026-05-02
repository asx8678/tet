defmodule Tet.Store.SQLite.Migrator do
  @moduledoc """
  Migration runner for the SQLite store adapter.

  `run!/0` applies PRAGMAs and runs pending migrations against the
  already-supervised Repo (called by `Application.start/2`).

  `run!/1` accepts keyword opts including `:database` and spins up a
  transient Repo for standalone migration (e.g., mix tasks).
  """

  alias Tet.Store.SQLite.{Connection, Repo}

  @doc """
  Applies PRAGMAs and runs all pending migrations using the already-running Repo.

  Called by `Application.start/2` after the Repo supervisor child is up.
  """
  @spec run!() :: :ok
  def run! do
    Connection.apply_and_verify!(Repo)
    Connection.ensure_auto_vacuum!(Repo)
    Ecto.Migrator.run(Repo, Connection.migrations_path(), :up, all: true, log: false)
    :ok
  end

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
