defmodule Tet.Store.SQLiteMigratorTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Tet.Store.SQLite.{Connection, Migrator, Repo}

  @expected_tables ~w(
    workspaces
    sessions
    tasks
    messages
    tool_runs
    approvals
    artifacts
    events
    workflows
    workflow_steps
    autosaves
    prompt_history_entries
    legacy_jsonl_imports
  )

  test "migration runner bootstraps an empty DB with all v0.3, journal, and compat tables" do
    db_path = unique_db_path("bootstrap")

    try do
      applied = Migrator.run!(database: db_path)
      assert length(applied) == 13

      with_repo(db_path, fn ->
        assert @expected_tables -- table_names() == []
        assert "schema_migrations" in table_names(include_schema_migrations?: true)

        assert column!("events", "session_id").notnull == 1
        assert column!("events", "seq").notnull == 1

        assert column!("approvals", "status").notnull == 1
        assert column!("approvals", "diff_artifact_id").notnull == 1

        assert column!("workflow_steps", "error").type == "BLOB"
        assert column!("workflow_steps", "idempotency_key").notnull == 1

        assert column!("artifacts", "inline_blob").type == "BLOB"
        assert column!("artifacts", "path").type == "TEXT"

        assert index?("approvals", "approvals_one_pending_per_session",
                 unique?: true,
                 partial?: true
               )

        assert index_sql("approvals_one_pending_per_session") =~ "WHERE status = 'pending'"

        assert index?("events", "events_session_seq", unique?: true)
        assert index_columns("events_session_seq") == ["session_id", "seq"]

        assert index?("artifacts", "artifacts_workspace_sha256_idx", unique?: true)
        assert index_columns("artifacts_workspace_sha256_idx") == ["workspace_id", "sha256"]

        assert index?("workflow_steps", "sqlite_autoindex_workflow_steps_2", unique?: true) or
                 unique_index_on?("workflow_steps", ["workflow_id", "idempotency_key"])
      end)
    after
      File.rm_rf!(Path.dirname(db_path))
    end
  end

  test "required PRAGMAs verify on the migration connection" do
    db_path = unique_db_path("pragmas")

    try do
      Migrator.run!(database: db_path)

      with_repo(db_path, fn ->
        Connection.apply_and_verify!(Repo)
        snapshot = Connection.pragma_snapshot!(Repo)

        assert snapshot.journal_mode == "wal"
        assert snapshot.synchronous == 1
        assert snapshot.foreign_keys == 1
        assert snapshot.busy_timeout == 5_000
        assert snapshot.temp_store == 2
        assert snapshot.cache_size == -20_000
        assert snapshot.mmap_size >= 268_435_456
        assert snapshot.auto_vacuum == :incremental
      end)
    after
      File.rm_rf!(Path.dirname(db_path))
    end
  end

  test "migrations roll back cleanly in reverse order" do
    db_path = unique_db_path("rollback")

    try do
      assert length(Migrator.run!(database: db_path)) == 13

      with_repo(db_path, fn ->
        previous_ignore_module_conflict = Code.compiler_options()[:ignore_module_conflict]

        down =
          try do
            Code.compiler_options(ignore_module_conflict: true)
            Ecto.Migrator.run(Repo, Connection.migrations_path(), :down, all: true, log: false)
          after
            Code.compiler_options(ignore_module_conflict: previous_ignore_module_conflict)
          end

        assert length(down) == 13
        assert table_names() == []
      end)
    after
      File.rm_rf!(Path.dirname(db_path))
    end
  end

  test "migration runner is idempotent when re-run" do
    db_path = unique_db_path("idempotent")

    try do
      assert length(Migrator.run!(database: db_path)) == 13
      assert Migrator.run!(database: db_path) == []

      with_repo(db_path, fn ->
        assert scalar!("SELECT COUNT(*) FROM schema_migrations") == 13
        assert scalar!("SELECT COUNT(DISTINCT version) FROM schema_migrations") == 13
      end)
    after
      File.rm_rf!(Path.dirname(db_path))
    end
  end

  test "WAL downgrade detection refuses rollback-journal mode" do
    db_path = unique_db_path("wal-downgrade")

    try do
      Migrator.run!(database: db_path)

      with_repo(db_path, fn ->
        SQL.query!(Repo, "PRAGMA journal_mode = DELETE;", [], log: false)

        assert_raise RuntimeError,
                     ~r/SQLite refused WAL mode|SQLite PRAGMA journal_mode expected/,
                     fn ->
                       Connection.verify_required_pragmas!(Repo)
                     end
      end)
    after
      File.rm_rf!(Path.dirname(db_path))
    end
  end

  @tag :read_only_filesystem
  test "migrator raises when a read-only database cannot enter WAL mode" do
    if match?({:win32, _}, :os.type()) do
      :ok
    else
      db_path = unique_db_path("readonly")
      File.mkdir_p!(Path.dirname(db_path))
      create_rollback_journal_database!(db_path)
      File.chmod!(db_path, 0o444)

      try do
        assert_raise RuntimeError,
                     ~r/(WAL|readonly|read-only|PRAGMA failed|Failed to start SQLite repo)/i,
                     fn ->
                       Migrator.run!(database: db_path)
                     end
      after
        File.chmod(db_path, 0o644)
        File.rm_rf!(Path.dirname(db_path))
      end
    end
  end

  defp with_repo(db_path, fun) do
    {:ok, pid} = Repo.start_link(Connection.repo_options(database: db_path))

    try do
      Connection.apply_and_verify!(Repo)
      fun.()
    after
      Supervisor.stop(pid, :normal, 15_000)
    end
  end

  defp table_names(opts \\ []) do
    include_schema_migrations? = Keyword.get(opts, :include_schema_migrations?, false)

    where =
      if include_schema_migrations? do
        "name NOT LIKE 'sqlite_%'"
      else
        "name NOT LIKE 'sqlite_%' AND name != 'schema_migrations'"
      end

    "SELECT name FROM sqlite_schema WHERE type = 'table' AND #{where} ORDER BY name"
    |> rows!()
    |> Enum.map(fn [name] -> name end)
  end

  defp column!(table, column_name) do
    table
    |> pragma_table_info()
    |> Enum.find(fn row -> row.name == column_name end) ||
      flunk("expected #{table}.#{column_name} to exist")
  end

  defp pragma_table_info(table) do
    "PRAGMA table_info('#{table}')"
    |> rows!()
    |> Enum.map(fn [cid, name, type, notnull, default_value, pk] ->
      %{cid: cid, name: name, type: type, notnull: notnull, default_value: default_value, pk: pk}
    end)
  end

  defp index?(table, index_name, opts) do
    expected_unique = Keyword.get(opts, :unique?)
    expected_partial = Keyword.get(opts, :partial?)

    table
    |> index_list()
    |> Enum.any?(fn index ->
      index.name == index_name and
        (is_nil(expected_unique) or index.unique == bool_int(expected_unique)) and
        (is_nil(expected_partial) or index.partial == bool_int(expected_partial))
    end)
  end

  defp unique_index_on?(table, expected_columns) do
    table
    |> index_list()
    |> Enum.filter(&(&1.unique == 1))
    |> Enum.any?(fn index -> index_columns(index.name) == expected_columns end)
  end

  defp index_list(table) do
    "PRAGMA index_list('#{table}')"
    |> rows!()
    |> Enum.map(fn row ->
      # SQLite returns: seq, name, unique, origin, partial.
      [seq, name, unique, origin, partial | _] = row
      %{seq: seq, name: name, unique: unique, origin: origin, partial: partial}
    end)
  end

  defp index_columns(index_name) do
    "PRAGMA index_info('#{index_name}')"
    |> rows!()
    |> Enum.map(fn [_seqno, _cid, name] -> name end)
  end

  defp index_sql(index_name) do
    scalar!("SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = '#{index_name}'")
  end

  defp scalar!(sql) do
    case rows!(sql) do
      [[value | _] | _] -> value
      other -> flunk("expected scalar result for #{sql}, got #{inspect(other)}")
    end
  end

  defp rows!(sql), do: SQL.query!(Repo, sql, [], log: false).rows

  defp bool_int(true), do: 1
  defp bool_int(false), do: 0

  defp create_rollback_journal_database!(db_path) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode = DELETE;")
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE sentinel (id INTEGER PRIMARY KEY);")
    :ok = Exqlite.Sqlite3.close(conn)
  end

  defp unique_db_path(prefix) do
    suffix =
      "#{System.pid()}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"

    System.tmp_dir!()
    |> Path.join("tet-sqlite-#{prefix}-#{suffix}")
    |> Path.join("tet.sqlite")
  end
end
