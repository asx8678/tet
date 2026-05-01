defmodule Tet.Store.SQLite.Connection do
  @moduledoc """
  SQLite connection setup and PRAGMA verification for `tet_store_sqlite`.

  SQLite PRAGMAs are connection state, not database-shaped fairy dust. Every
  connection that touches `.tet/tet.sqlite` must run the required block and then
  verify WAL actually engaged. In particular, `PRAGMA journal_mode = WAL` can
  fail or be refused on read-only/odd VFS paths; falling back to `delete` mode
  would break the WAL concurrency contract.

  Required connection PRAGMAs, per the Phase 1 design and SQLite docs:

    * `journal_mode = WAL` — concurrent readers plus a single writer
      (sqlite.org/wal.html).
    * `synchronous = NORMAL` — WAL-recommended durability/performance point
      (sqlite.org/pragma.html#pragma_synchronous).
    * `foreign_keys = ON` — SQLite defaults are per-connection; trusting the
      default is how referential integrity quietly leaves the building.
    * `busy_timeout = 5000` — protects against checkpoint/external contention;
      it is not permission to add a write pool.
    * `temp_store = MEMORY`.
    * `cache_size = -20000` — negative means KiB, not pages.
    * `mmap_size = 268435456` — 256 MiB mmap ceiling for local workspace DBs.

  `auto_vacuum = INCREMENTAL` is handled separately as a database-creation
  invariant before migrations create tables. It is intentionally not part of the
  per-connection PRAGMA block.
  """

  alias Ecto.Adapters.SQL
  alias Tet.Store.SQLite.Repo

  @default_database_path ".tet/tet.sqlite"
  @busy_timeout_ms 5_000
  @cache_size_kib -20_000
  @mmap_size_bytes 268_435_456

  @required_pragmas [
    "PRAGMA journal_mode = WAL;",
    "PRAGMA synchronous = NORMAL;",
    "PRAGMA foreign_keys = ON;",
    "PRAGMA busy_timeout = 5000;",
    "PRAGMA temp_store = MEMORY;",
    "PRAGMA cache_size = -20000;",
    "PRAGMA mmap_size = 268435456;"
  ]

  @doc "Returns the required per-connection PRAGMA SQL in the mandated order."
  @spec required_pragmas() :: [String.t()]
  def required_pragmas, do: @required_pragmas

  @doc "Returns the resolved default DB path for the workspace-local SQLite DB."
  @spec default_database_path() :: String.t()
  def default_database_path do
    Application.get_env(:tet_store_sqlite, :database_path, @default_database_path)
  end

  @doc "Builds Repo options with the required SQLite connection settings."
  @spec repo_options(keyword()) :: keyword()
  def repo_options(opts \\ []) when is_list(opts) do
    configured = Application.get_env(:tet_store_sqlite, Repo, [])
    database = database_path(opts, configured)

    configured
    |> Keyword.merge(
      database: database,
      pool_size: Keyword.get(opts, :pool_size, Keyword.get(configured, :pool_size, 1)),
      journal_mode: :wal,
      synchronous: :normal,
      foreign_keys: :on,
      busy_timeout: @busy_timeout_ms,
      temp_store: :memory,
      cache_size: @cache_size_kib,
      custom_pragmas: [{"auto_vacuum", 2}, {"mmap_size", @mmap_size_bytes}],
      default_transaction_mode: :immediate,
      auto_vacuum: :incremental,
      priv: Keyword.get(configured, :priv, "priv/repo")
    )
  end

  @doc "Ensures the database parent directory exists for normal filesystem paths."
  @spec ensure_parent_dir!(String.t()) :: :ok
  def ensure_parent_dir!(":memory:"), do: :ok
  def ensure_parent_dir!(":memory"), do: :ok
  def ensure_parent_dir!("file:" <> _uri), do: :ok

  def ensure_parent_dir!(database) when is_binary(database) do
    database
    |> Path.dirname()
    |> File.mkdir_p!()

    :ok
  end

  @doc "Runs the creation-only `auto_vacuum=INCREMENTAL` invariant and verifies it."
  @spec ensure_auto_vacuum!(module()) :: :ok
  def ensure_auto_vacuum!(repo \\ Repo) do
    if empty_schema?(repo) do
      query!(repo, "PRAGMA auto_vacuum = INCREMENTAL;")
    end

    case normalize_auto_vacuum(query_scalar!(repo, "PRAGMA auto_vacuum;")) do
      :incremental ->
        :ok

      other ->
        raise "SQLite auto_vacuum must be INCREMENTAL before schema creation; got #{inspect(other)}. " <>
                "Changing this after tables exist requires a full VACUUM, which is not a runtime toy."
    end
  end

  @doc "Runs required PRAGMAs and raises unless WAL and all required values verify."
  @spec apply_and_verify!(module()) :: :ok
  def apply_and_verify!(repo \\ Repo) do
    Enum.each(@required_pragmas, fn sql ->
      query!(repo, sql)
    end)

    verify_required_pragmas!(repo)
  end

  @doc "Verifies required PRAGMA values without mutating the connection."
  @spec verify_required_pragmas!(module()) :: :ok
  def verify_required_pragmas!(repo \\ Repo) do
    snapshot = pragma_snapshot!(repo)

    unless snapshot.journal_mode == "wal" do
      raise "SQLite refused WAL mode; PRAGMA journal_mode returned #{inspect(snapshot.journal_mode)}. " <>
              "Refusing to start because rollback-journal fallback breaks WAL-mode concurrency."
    end

    assert_pragma!(snapshot.synchronous, 1, :synchronous)
    assert_pragma!(snapshot.foreign_keys, 1, :foreign_keys)
    assert_pragma!(snapshot.busy_timeout, @busy_timeout_ms, :busy_timeout)
    assert_pragma!(snapshot.temp_store, 2, :temp_store)
    assert_pragma!(snapshot.cache_size, @cache_size_kib, :cache_size)

    if snapshot.mmap_size < @mmap_size_bytes do
      raise "SQLite PRAGMA mmap_size expected at least #{@mmap_size_bytes}, got #{inspect(snapshot.mmap_size)}"
    end

    :ok
  end

  @doc "Returns the currently observed PRAGMA values for tests and doctor surfaces."
  @spec pragma_snapshot!(module()) :: map()
  def pragma_snapshot!(repo \\ Repo) do
    %{
      journal_mode: normalize_text(query_scalar!(repo, "PRAGMA journal_mode;")),
      synchronous: normalize_integer(query_scalar!(repo, "PRAGMA synchronous;")),
      foreign_keys: normalize_integer(query_scalar!(repo, "PRAGMA foreign_keys;")),
      busy_timeout: normalize_integer(query_scalar!(repo, "PRAGMA busy_timeout;")),
      temp_store: normalize_integer(query_scalar!(repo, "PRAGMA temp_store;")),
      cache_size: normalize_integer(query_scalar!(repo, "PRAGMA cache_size;")),
      mmap_size: normalize_integer(query_scalar!(repo, "PRAGMA mmap_size;")),
      auto_vacuum: normalize_auto_vacuum(query_scalar!(repo, "PRAGMA auto_vacuum;"))
    }
  end

  @doc "Returns the compiled/release-safe migrations path under this app's priv dir."
  @spec migrations_path() :: String.t()
  def migrations_path do
    case :code.priv_dir(:tet_store_sqlite) do
      priv when is_list(priv) -> Path.join(List.to_string(priv), "repo/migrations")
      {:error, _} -> Path.expand("../../../../priv/repo/migrations", __DIR__)
    end
  end

  defp query!(repo, sql) do
    SQL.query!(repo, sql, [], timeout: 15_000, log: false)
  rescue
    exception ->
      raise "SQLite PRAGMA failed: #{sql} -> #{Exception.message(exception)}"
  end

  defp query_scalar!(repo, sql) do
    case query!(repo, sql).rows do
      [[value | _rest] | _rows] -> value
      other -> raise "SQLite PRAGMA query returned unexpected rows for #{sql}: #{inspect(other)}"
    end
  end

  defp empty_schema?(repo) do
    sql = """
    SELECT COUNT(*)
    FROM sqlite_schema
    WHERE type = 'table'
      AND name NOT LIKE 'sqlite_%'
    """

    normalize_integer(query_scalar!(repo, sql)) == 0
  end

  defp database_path(opts, configured) do
    Keyword.get(opts, :database) ||
      Keyword.get(opts, :database_path) ||
      Keyword.get(opts, :path) ||
      Keyword.get(configured, :database) ||
      default_database_path()
  end

  defp assert_pragma!(actual, expected, name) do
    unless actual == expected do
      raise "SQLite PRAGMA #{name} expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end

  defp normalize_text(value) when is_binary(value), do: String.downcase(value)
  defp normalize_text(value), do: value |> to_string() |> String.downcase()

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.to_integer()
  end

  defp normalize_auto_vacuum(value) do
    case normalize_integer(value) do
      0 -> :none
      1 -> :full
      2 -> :incremental
      other -> other
    end
  end
end
