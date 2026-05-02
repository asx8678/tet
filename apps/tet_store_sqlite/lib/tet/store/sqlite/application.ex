defmodule Tet.Store.SQLite.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    database = Tet.Store.SQLite.Connection.default_database_path()

    # Ensure parent dir exists before Repo tries to open the file
    Tet.Store.SQLite.Connection.ensure_parent_dir!(database)

    children = [
      {Tet.Store.SQLite.Repo, Tet.Store.SQLite.Connection.repo_options()}
    ]

    opts = [strategy: :one_for_one, name: Tet.Store.SQLite.Supervisor]

    with {:ok, sup} <- Supervisor.start_link(children, opts) do
      if Application.get_env(:tet_store_sqlite, :migrate_on_start, true) do
        Tet.Store.SQLite.Migrator.run!()
      end

      {:ok, sup}
    end
  end
end
