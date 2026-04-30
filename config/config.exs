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

config :tet_cli,
  release_profile: :tet_standalone
