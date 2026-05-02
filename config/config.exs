import Config

config :tet_runtime,
  release_profile: :tet_standalone,
  standalone_applications: [:tet_core, :tet_store_sqlite, :tet_runtime, :tet_cli],
  store_adapter: Tet.Store.SQLite,
  store_path: ".tet/messages.jsonl",
  provider: :mock,
  openai_compatible: [
    base_url: "https://api.openai.com/v1",
    model: "gpt-4o-mini",
    timeout: 60_000
  ]

config :tet_store_sqlite,
  ecto_repos: [Tet.Store.SQLite.Repo],
  database_path: ".tet/tet.sqlite",
  migrate_on_start: config_env() != :test

config :tet_store_sqlite, Tet.Store.SQLite.Repo,
  database: ".tet/tet.sqlite",
  pool_size: 1,
  journal_mode: :wal,
  synchronous: :normal,
  foreign_keys: :on,
  busy_timeout: 5_000,
  temp_store: :memory,
  cache_size: -20_000,
  custom_pragmas: [{"auto_vacuum", 2}, {"mmap_size", 268_435_456}],
  default_transaction_mode: :immediate,
  priv: "priv/repo"

config :tet_cli,
  release_profile: :tet_standalone

# Import environment-specific config (dev.exs, test.exs, prod.exs)
if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
