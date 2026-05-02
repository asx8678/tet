import Config

# SQLite test configuration: use a temp database and run migrations
config :tet_store_sqlite,
  migrate_on_start: true,
  database_path: Path.join(System.tmp_dir!(), "tet_test.sqlite")

config :tet_store_sqlite, Tet.Store.SQLite.Repo,
  database: Path.join(System.tmp_dir!(), "tet_test.sqlite"),
  pool_size: 1
