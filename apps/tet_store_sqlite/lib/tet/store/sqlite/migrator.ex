defmodule Tet.Store.SQLite.Migrator do
  @moduledoc """
  Release-safe SQLite migration runner for `tet_store_sqlite`.

  This is deliberately a normal Elixir module called from
  `Tet.Store.SQLite.Application.start/2`, not `mix ecto.migrate`. Standalone
  releases do not ship Mix, and pretending they do is how migration code passes
  in dev and detonates in production.

  The runner starts one temporary SQLite repo connection, applies the creation
  and per-connection PRAGMA invariants, executes pending Ecto migrations from
  the app's `priv/repo/migrations` directory, verifies PRAGMAs again, then stops
  the temporary repo. Phase 3 owns the permanent single-writer process; Phase 2
  only bootstraps the schema safely.
  """

  require Logger

  alias Tet.Store.SQLite.{Connection, Repo}

  @doc "Runs all pending SQLite migrations and returns the applied versions."
  @spec run!(keyword()) :: [integer()]
  def run!(opts \\ []) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    repo_opts = Connection.repo_options(opts)
    database = Keyword.fetch!(repo_opts, :database)
    migrations_path = Keyword.get(opts, :migrations_path, Connection.migrations_path())

    Connection.ensure_parent_dir!(database)

    Logger.info("Starting tet_store_sqlite migrations for #{inspect(database)}")

    {pid, stop?} = start_repo!(repo, repo_opts)

    try do
      Connection.ensure_auto_vacuum!(repo)
      Connection.apply_and_verify!(repo)

      applied = run_ecto_migrations(repo, migrations_path, opts)

      Connection.apply_and_verify!(repo)
      Logger.info("Finished tet_store_sqlite migrations; applied=#{inspect(applied)}")
      applied
    after
      if stop? do
        stop_repo(pid)
      end
    end
  end

  defp run_ecto_migrations(repo, migrations_path, opts) do
    previous_ignore_module_conflict = Code.compiler_options()[:ignore_module_conflict]

    try do
      Code.compiler_options(ignore_module_conflict: true)

      Ecto.Migrator.run(repo, migrations_path, :up,
        all: true,
        log: Keyword.get(opts, :log, false)
      )
    after
      Code.compiler_options(ignore_module_conflict: previous_ignore_module_conflict)
    end
  end

  defp start_repo!(repo, repo_opts) do
    case repo.start_link(repo_opts) do
      {:ok, pid} ->
        {pid, true}

      {:error, {:already_started, pid}} ->
        {pid, false}

      {:error, reason} ->
        raise "Failed to start SQLite repo for migrations: #{inspect(reason)}"
    end
  end

  defp stop_repo(pid) do
    case Supervisor.stop(pid, :normal, 15_000) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  catch
    :exit, {:noproc, _} -> :ok
  end
end
