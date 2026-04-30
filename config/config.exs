import Config

config :tet_runtime,
  release_profile: :tet_standalone,
  standalone_applications: [:tet_core, :tet_store_sqlite, :tet_runtime, :tet_cli],
  store_adapter: Tet.Store.SQLite

config :tet_cli,
  release_profile: :tet_standalone
