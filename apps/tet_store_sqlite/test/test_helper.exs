# Delete stale test DB for clean state
db =
  Application.get_env(:tet_store_sqlite, :database_path) ||
    Path.join(System.tmp_dir!(), "tet_test.sqlite")

for ext <- ["", "-shm", "-wal"], do: File.rm(db <> ext)

# Start the app (this starts Repo + runs migrations via Application.start)
{:ok, _} = Application.ensure_all_started(:tet_store_sqlite)

ExUnit.start()
