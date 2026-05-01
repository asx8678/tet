defmodule Tet.Store.SQLite.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:tet_store_sqlite, :migrate_on_start, true) do
      Tet.Store.SQLite.Migrator.run!()
    end

    children = []

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Tet.Store.SQLite.Supervisor
    )
  end
end
