defmodule Tet.Store.SQLite.CrashRecoveryTest do
  @moduledoc """
  Verifies SQLite crash-recovery invariants under WAL mode.

  Three invariants tested:

    1. **No partial writes.** A process killed mid-transaction must leave zero
       uncommitted rows. SQLite WAL guarantees that uncommitted frames are
       rolled back when the connection holding the write lock dies
       (sqlite.org/wal.html § 3.1). Tested by killing a spawned process that
       holds an open BEGIN IMMEDIATE with an uncommitted INSERT, then verifying
       the phantom row is absent via the still-alive Repo.

    2. **Writer recovery.** After a full Application stop/start cycle (the
       production crash-recovery path), the writer must accept new writes
       through the public API: Repo opens → PRAGMAs applied by ecto_sqlite3 →
       Migrator.run! runs pending migrations → writer ready.

    3. **WAL mode and critical PRAGMAs survive restart.** journal_mode is
       persistent on the database file (sqlite.org/pragma.html#pragma_journal_mode);
       foreign_keys, synchronous, and busy_timeout are per-connection and must
       be re-applied by ecto_sqlite3 on every new connection.

  async: false — we stop/restart the application and kill processes.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Tet.Store.SQLite.Connection
  alias Tet.Store.SQLite.Repo

  # FK-ordered cleanup: children first, then parents.
  @cleanup_tables [
    "legacy_jsonl_imports",
    "project_lessons",
    "persistent_memories",
    "findings",
    "repairs",
    "error_log",
    "checkpoints",
    "workflow_steps",
    "workflows",
    "events",
    "approvals",
    "artifacts",
    "tool_runs",
    "messages",
    "autosaves",
    "prompt_history_entries",
    "tasks",
    "sessions",
    "workspaces"
  ]

  setup do
    ensure_app_started!()

    # After an Application stop/start cycle (from this or other test files
    # like migrator_test), the test DB in tmp may have been recreated.
    # Re-run the migrator to ensure schema + PRAGMAs are in place.
    Tet.Store.SQLite.Migrator.run!()

    for table <- @cleanup_tables do
      SQL.query!(Repo, "DELETE FROM #{table}", [])
    end

    # Build the FK parent chain (workspace → session) that event inserts need.
    n = System.unique_integer([:positive, :monotonic])
    ws_id = "ws_crash_#{n}"
    ses_id = "ses_crash_#{n}"

    {:ok, _ws} =
      Tet.Store.SQLite.create_workspace(%{
        id: ws_id,
        name: "crash-test",
        root_path: "/tmp/crash-test-#{ws_id}",
        tet_dir_path: "/tmp/crash-test-#{ws_id}/.tet",
        trust_state: :trusted
      })

    {:ok, _ses} =
      Tet.Store.SQLite.create_session(%{
        id: ses_id,
        workspace_id: ws_id,
        short_id: String.slice(ses_id, 0, 8),
        mode: :chat,
        status: :idle
      })

    # Flush schema and FK parents from the WAL to the main database file.
    # Under WAL mode, all writes (including DDL from migrations) live in the
    # -wal file until a checkpoint moves them. A brutal process kill can
    # leave the main file without tables if no checkpoint has run since
    # migration. This checkpoint ensures the schema survives unconditionally.
    # See sqlite.org/pragma.html#pragma_wal_checkpoint
    SQL.query!(Repo, "PRAGMA wal_checkpoint(TRUNCATE)", [])

    on_exit(fn -> ensure_app_started!() end)

    {:ok, ws_id: ws_id, ses_id: ses_id}
  end

  # ── Test 1: No partial writes survive a killed writer process ────────

  test "killing a writer process mid-transaction leaves no partial writes", %{ses_id: ses_id} do
    test_pid = self()
    phantom_id = "evt_phantom_#{System.unique_integer([:positive])}"

    # Spawn a worker that holds a transaction open with an uncommitted INSERT.
    # This simulates a GenServer processing a write that crashes mid-flight —
    # the most common real-world failure mode for the single-writer.
    {:ok, worker_pid} =
      Task.start(fn ->
        try do
          Repo.transaction(
            fn ->
              # Raw INSERT so we control the exact id. The row exists inside
              # this transaction but has NOT been committed.
              SQL.query!(
                Repo,
                """
                INSERT INTO events (id, session_id, seq, type, payload, metadata, inserted_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                """,
                [
                  phantom_id,
                  ses_id,
                  9999,
                  "crash_test_phantom",
                  "{}",
                  "{}",
                  System.os_time(:second)
                ]
              )

              # Sanity check: the row IS visible inside this transaction.
              %{rows: [[1]]} =
                SQL.query!(Repo, "SELECT COUNT(*) FROM events WHERE id = ?1", [phantom_id])

              # Signal the test process: INSERT done, transaction still open.
              send(test_pid, :mid_transaction)

              # Block forever. The transaction stays open (BEGIN IMMEDIATE held)
              # until someone kills us or the connection underneath dies.
              receive do
                :__never__ -> :ok
              end
            end,
            timeout: :infinity
          )
        catch
          :exit, _reason -> :crashed
        end
      end)

    # Wait for the worker to reach the blocking point inside the transaction.
    assert_receive :mid_transaction, 5_000

    # Kill the worker with :kill (untrappable) — simulates a process crash.
    # SQLite will roll back the uncommitted transaction when the connection
    # pool reclaims the dead checkout.
    worker_ref = Process.monitor(worker_pid)
    Process.exit(worker_pid, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :killed}, 5_000

    # Give DBConnection a moment to reclaim the dead checkout and release
    # the SQLite write lock back to the pool.
    Process.sleep(200)

    # ── THE INVARIANT ──
    # The phantom event must NOT exist. Per sqlite.org/wal.html § 3.1,
    # uncommitted WAL frames are discarded during recovery. The transaction
    # was never committed, so the INSERT must be rolled back.
    %{rows: [[count]]} =
      SQL.query!(Repo, "SELECT COUNT(*) FROM events WHERE id = ?1", [phantom_id])

    assert count == 0,
           "Phantom event #{phantom_id} from a killed-mid-transaction must not persist. " <>
             "Got count=#{count}. Either the transaction committed before the kill, " <>
             "or WAL recovery failed to roll it back — a durability bug."

    # Also verify that the FK parent data (checkpointed in setup) is intact
    # and the writer can still service reads after the killed checkout.
    %{rows: [[ses_count]]} =
      SQL.query!(Repo, "SELECT COUNT(*) FROM sessions WHERE id = ?1", [ses_id])

    assert ses_count == 1, "Checkpointed session must survive the killed transaction"
  end

  # ── Test 2: Writer accepts writes after full application restart ─────

  test "writer accepts new writes after application restart", %{ws_id: _ws_id, ses_id: _ses_id} do
    # Full application stop → start cycle. This is the production crash-
    # recovery path: Repo closes → connections released → on restart:
    # Repo opens → ecto_sqlite3 applies PRAGMAs → Migrator.run! checks
    # migrations → writer accepts traffic.
    :ok = Application.stop(:tet_store_sqlite)
    {:ok, _} = Application.ensure_all_started(:tet_store_sqlite)

    # After restart, create fresh FK parents. The test DB in tmp may be
    # recreated by the adapter; what matters is the writer is functional.
    n = System.unique_integer([:positive, :monotonic])
    fresh_ws = "ws_post_restart_#{n}"
    fresh_ses = "ses_post_restart_#{n}"

    assert {:ok, _ws} =
             Tet.Store.SQLite.create_workspace(%{
               id: fresh_ws,
               name: "post-restart-workspace",
               root_path: "/tmp/post-restart-#{fresh_ws}",
               tet_dir_path: "/tmp/post-restart-#{fresh_ws}/.tet",
               trust_state: :trusted
             })

    assert {:ok, _ses} =
             Tet.Store.SQLite.create_session(%{
               id: fresh_ses,
               workspace_id: fresh_ws,
               short_id: String.slice(fresh_ses, 0, 8),
               mode: :chat,
               status: :idle
             })

    # Write through the public API — full path including seq allocation,
    # domain struct construction, changeset validation, and Repo.insert.
    assert {:ok, event} =
             Tet.Store.SQLite.emit_event(%{
               session_id: fresh_ses,
               type: :session_started,
               payload: %{recovered: true}
             })

    assert event.session_id == fresh_ses
    assert event.type == :session_started
    assert event.seq >= 1, "seq must be allocated by insert_event_with_seq"

    # Verify the event round-trips through a read.
    assert {:ok, events} = Tet.Store.SQLite.list_events(fresh_ses, [])
    assert length(events) >= 1
    assert Enum.any?(events, &(&1.id == event.id))

    # Write a second event to verify seq monotonicity.
    assert {:ok, event2} =
             Tet.Store.SQLite.emit_event(%{
               session_id: fresh_ses,
               type: :session_started,
               payload: %{second_write: true}
             })

    assert event2.seq > event.seq,
           "Sequential writes must produce monotonically increasing seq: " <>
             "first=#{event.seq}, second=#{event2.seq}"
  end

  # ── Test 3: WAL mode and critical PRAGMAs survive application restart ─

  test "WAL mode and critical PRAGMAs are active after application restart" do
    :ok = Application.stop(:tet_store_sqlite)
    {:ok, _} = Application.ensure_all_started(:tet_store_sqlite)

    snapshot = Connection.pragma_snapshot!()

    # journal_mode is persistent on the database file AND re-sent by
    # ecto_sqlite3 on connection init. Either mechanism ensures WAL.
    assert snapshot.journal_mode == "wal",
           "WAL mode must survive restart; " <>
             "got journal_mode=#{inspect(snapshot.journal_mode)}. " <>
             "Per sqlite.org/pragma.html#pragma_journal_mode, journal_mode is persistent " <>
             "and ecto_sqlite3 re-sends it on connection open."

    # foreign_keys is per-connection (SQLite defaults to OFF — yes, really).
    # The adapter must re-set it on every new connection. If this fails,
    # referential integrity is silently disabled — a data corruption vector.
    assert snapshot.foreign_keys == 1,
           "foreign_keys must be ON after restart (SQLite defaults to OFF per-connection)"

    # synchronous = NORMAL (1) is the WAL-blessed setting per
    # sqlite.org/pragma.html#pragma_synchronous. OFF (0) risks corruption
    # on power loss; FULL (2) is for rollback-journal mode.
    assert snapshot.synchronous == 1,
           "synchronous must be NORMAL (1) after restart"

    # busy_timeout protects against checkpoint-induced contention.
    assert snapshot.busy_timeout == 5000,
           "busy_timeout must be 5000ms after restart"
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp ensure_app_started! do
    case Application.ensure_all_started(:tet_store_sqlite) do
      {:ok, _} -> :ok
      {:error, {:already_started, :tet_store_sqlite}} -> :ok
    end
  end
end
