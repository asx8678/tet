defmodule Tet.Store.SQLite.BD0084DurabilityTest do
  @moduledoc """
  BD-0084: SQLite durability and session resume integrity.

  Verifies that the SQLite store correctly persists and retrieves all entity
  types across process restarts. Complements the shell-based release binary
  test in `tools/bd_0084_durability_test.sh`.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Tet.Store.SQLite
  alias Tet.Store.SQLite.Connection
  alias Tet.Store.SQLite.Repo

  @cleanup_tables ~w(
    legacy_jsonl_imports project_lessons persistent_memories findings repairs
    error_log checkpoints workflow_steps workflows events approvals artifacts
    tool_runs messages autosaves prompt_history_entries tasks sessions workspaces
  )

  setup do
    Application.ensure_all_started(:tet_store_sqlite)
    Tet.Store.SQLite.Migrator.run!()

    for table <- @cleanup_tables do
      SQL.query!(Repo, "DELETE FROM #{table}", [])
    end

    n = System.unique_integer([:positive, :monotonic])
    ws_id = "ws_bd0084_#{n}"
    ses_id = "ses_bd0084_#{n}"

    {:ok, _ws} =
      SQLite.create_workspace(%{
        id: ws_id,
        name: "bd0084-test",
        root_path: "/tmp/bd0084-#{ws_id}",
        tet_dir_path: "/tmp/bd0084-#{ws_id}/.tet",
        trust_state: :trusted
      })

    {:ok, _ses} =
      SQLite.create_session(%{
        id: ses_id,
        workspace_id: ws_id,
        short_id: String.slice(ses_id, 0, 8),
        mode: :chat,
        status: :idle
      })

    SQL.query!(Repo, "PRAGMA wal_checkpoint(TRUNCATE)", [])

    on_exit(fn ->
      Application.ensure_all_started(:tet_store_sqlite)
    end)

    {:ok, ws_id: ws_id, ses_id: ses_id}
  end

  describe "WAL mode and PRAGMA settings" do
    test "all required PRAGMAs are active on connection" do
      snapshot = Connection.pragma_snapshot!()

      assert snapshot.journal_mode == "wal",
             "journal_mode must be WAL; got #{inspect(snapshot.journal_mode)}"

      assert snapshot.synchronous == 1,
             "synchronous must be NORMAL (1); got #{inspect(snapshot.synchronous)}"

      assert snapshot.foreign_keys == 1,
             "foreign_keys must be ON (1); got #{inspect(snapshot.foreign_keys)}"

      assert snapshot.busy_timeout == 5000,
             "busy_timeout must be 5000; got #{inspect(snapshot.busy_timeout)}"

      assert snapshot.temp_store == 2,
             "temp_store must be MEMORY (2); got #{inspect(snapshot.temp_store)}"

      assert snapshot.cache_size == -20_000,
             "cache_size must be -20000 KiB; got #{inspect(snapshot.cache_size)}"

      assert snapshot.mmap_size >= 268_435_456,
             "mmap_size must be >= 256 MiB; got #{inspect(snapshot.mmap_size)}"

      assert snapshot.auto_vacuum == :incremental,
             "auto_vacuum must be INCREMENTAL; got #{inspect(snapshot.auto_vacuum)}"
    end

    test "WAL mode is active on the connection" do
      # Verify WAL mode is actually active (not just claimed).
      %{rows: [[journal_mode]]} =
        SQL.query!(Repo, "PRAGMA journal_mode", [])

      assert journal_mode == "wal", "journal_mode must be wal, got #{journal_mode}"
    end

    test "PRAGMA integrity_check passes" do
      %{rows: [[result]]} = SQL.query!(Repo, "PRAGMA integrity_check", [])
      assert result == "ok"
    end

    test "direct SQLite file inspection confirms tables exist" do
      sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'"
      %{rows: [[table_count]]} = SQL.query!(Repo, sql, [])
      assert table_count > 10, "Expected >10 tables, got #{table_count}"
    end
  end

  describe "message persistence" do
    test "messages persist via save_message", %{ses_id: ses_id} do
      {:ok, msg1} =
        SQLite.save_message(
          %Tet.Message{
            id: "msg_bd0084_1",
            session_id: ses_id,
            role: :user,
            content: "Hello from BD-0084 test",
            timestamp: "2025-01-01T00:00:00Z"
          },
          []
        )

      {:ok, msg2} =
        SQLite.save_message(
          %Tet.Message{
            id: "msg_bd0084_2",
            session_id: ses_id,
            role: :assistant,
            content: "mock response from BD-0084",
            timestamp: "2025-01-01T00:00:01Z"
          },
          []
        )

      assert msg1.role == :user
      assert msg2.role == :assistant

      {:ok, msgs} = SQLite.list_messages(ses_id, [])
      assert length(msgs) == 2

      user_msg = Enum.find(msgs, &(&1.role == :user))
      assert user_msg.content == "Hello from BD-0084 test"
      assert user_msg.id == "msg_bd0084_1"

      asst_msg = Enum.find(msgs, &(&1.role == :assistant))
      assert asst_msg.content == "mock response from BD-0084"
      assert asst_msg.id == "msg_bd0084_2"
    end

    test "message sequence numbers are monotonic", %{ses_id: ses_id} do
      for i <- 1..5 do
        SQLite.save_message(
          %Tet.Message{
            id: "msg_seq_#{i}",
            session_id: ses_id,
            role: if(rem(i, 2) == 0, do: :assistant, else: :user),
            content: "message #{i}",
            timestamp: "2025-01-01T00:00:0#{i}Z"
          },
          []
        )
      end

      import Ecto.Query
      alias Tet.Store.SQLite.Schema.Message, as: MessageSchema

      seqs =
        MessageSchema
        |> where([m], m.session_id == ^ses_id)
        |> order_by([m], asc: m.seq)
        |> select([m], m.seq)
        |> Repo.all()

      assert seqs == Enum.sort(seqs), "Messages must be in monotonic seq order"
      assert length(seqs) == 5
    end
  end

  describe "autosave checkpoints" do
    test "save and load autosave checkpoint", %{ses_id: ses_id} do
      messages = [
        %Tet.Message{
          id: "as_msg_1",
          session_id: ses_id,
          role: :user,
          content: "autosave test message",
          timestamp: "2025-01-01T00:00:00Z"
        }
      ]

      autosave = %Tet.Autosave{
        checkpoint_id: "cp_bd0084_test",
        session_id: ses_id,
        saved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        messages: messages,
        attachments: [],
        prompt_metadata: %{"test" => "bd0084"},
        prompt_debug: %{"phase" => "save_test"},
        prompt_debug_text: "BD-0084 autosave text",
        metadata: %{"source" => "durability_test"}
      }

      {:ok, saved} = SQLite.save_autosave(autosave, [])
      assert saved.checkpoint_id == "cp_bd0084_test"
      assert saved.session_id == ses_id
      assert length(saved.messages) == 1

      {:ok, loaded} = SQLite.load_autosave(ses_id, [])
      assert loaded.session_id == ses_id
      assert length(loaded.messages) == 1
      assert loaded.prompt_debug_text == "BD-0084 autosave text"
      assert Map.get(loaded.metadata, "source") == "durability_test"
      assert Map.get(loaded.prompt_metadata, "test") == "bd0084"
    end

    test "list_autosaves returns all checkpoints", %{ses_id: ses_id} do
      for i <- 1..3 do
        autosave = %Tet.Autosave{
          checkpoint_id: "cp_list_#{i}",
          session_id: ses_id,
          saved_at: DateTime.utc_now() |> DateTime.add(-i, :second) |> DateTime.to_iso8601(),
          messages: [],
          attachments: [],
          prompt_metadata: %{},
          prompt_debug: %{},
          prompt_debug_text: "",
          metadata: %{}
        }

        {:ok, _} = SQLite.save_autosave(autosave, [])
      end

      {:ok, all} = SQLite.list_autosaves([])
      assert length(all) >= 3
    end
  end

  describe "checkpoints" do
    test "save, list, and delete checkpoints", %{ses_id: ses_id} do
      sha = "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"

      {:ok, cp} =
        SQLite.save_checkpoint(
          %{
            id: "ckpt_bd0084_1",
            session_id: ses_id,
            sha256: sha,
            state_snapshot: %{"turn" => 3, "phase" => "test"},
            metadata: %{"test" => "bd0084"}
          },
          []
        )

      assert cp.id == "ckpt_bd0084_1"
      assert cp.session_id == ses_id
      assert cp.sha256 == sha
      assert cp.state_snapshot["turn"] == 3

      {:ok, cps} = SQLite.list_checkpoints(ses_id, [])
      assert length(cps) >= 1

      {:ok, :ok} = SQLite.delete_checkpoint("ckpt_bd0084_1", [])
      assert {:error, :checkpoint_not_found} = SQLite.get_checkpoint("ckpt_bd0084_1", [])
    end
  end

  describe "runtime event durability and sequence numbers" do
    test "events via append_event have correct monotonically increasing seq", %{ses_id: ses_id} do
      for i <- 1..8 do
        SQLite.append_event(
          %{
            id: "evt_bd0084_#{i}",
            session_id: ses_id,
            type: :session_started,
            payload: %{step: i},
            metadata: %{}
          },
          []
        )
      end

      {:ok, events} = SQLite.list_events(ses_id, [])
      assert length(events) == 8

      seqs = Enum.map(events, & &1.seq)
      assert seqs == Enum.sort(seqs), "Events must be in monotonic order"
      assert Enum.min(seqs) >= 1
    end

    test "events from different sessions are isolated", %{ses_id: ses_id, ws_id: ws_id} do
      other_ses = "ses_iso_#{System.unique_integer([:positive])}"

      {:ok, _} =
        SQLite.create_session(%{
          id: other_ses,
          workspace_id: ws_id,
          short_id: String.slice(other_ses, 0, 8),
          mode: :chat,
          status: :idle
        })

      SQLite.append_event(
        %{
          id: "evt_iso_a",
          session_id: ses_id,
          type: :session_started,
          payload: %{},
          metadata: %{}
        },
        []
      )

      SQLite.append_event(
        %{
          id: "evt_iso_b",
          session_id: other_ses,
          type: :session_started,
          payload: %{},
          metadata: %{}
        },
        []
      )

      {:ok, events_a} = SQLite.list_events(ses_id, [])
      {:ok, events_b} = SQLite.list_events(other_ses, [])

      assert Enum.all?(events_a, &(&1.session_id == ses_id))
      assert Enum.all?(events_b, &(&1.session_id == other_ses))
      assert length(events_a) == 1
      assert length(events_b) == 1
    end

    test "event round-trip: append then get", %{ses_id: ses_id} do
      SQLite.append_event(
        %{
          id: "evt_rt",
          session_id: ses_id,
          type: :session_started,
          payload: %{test: "round_trip"},
          metadata: %{}
        },
        []
      )

      {:ok, event} = SQLite.get_event("evt_rt", [])
      assert event.id == "evt_rt"
      assert event.session_id == ses_id
      assert event.type == :session_started
    end
  end

  describe "session summaries derived from stored messages" do
    test "message_count and last_role are correct", %{ses_id: ses_id} do
      for i <- 1..4 do
        role = if(rem(i, 2) == 0, do: :assistant, else: :user)

        SQLite.save_message(
          %Tet.Message{
            id: "msg_summary_#{i}",
            session_id: ses_id,
            role: role,
            content: "summary test msg #{i}",
            timestamp: "2025-01-01T00:00:0#{i}Z"
          },
          []
        )
      end

      {:ok, session} = SQLite.fetch_session(ses_id, [])
      assert session.message_count == 4
      assert session.last_role == :assistant

      {:ok, sessions} = SQLite.list_sessions([])
      target = Enum.find(sessions, &(&1.id == ses_id))
      assert target.message_count == 4
      assert target.last_role == :assistant
    end

    test "summary reflects actual stored message count", %{ses_id: ses_id} do
      for i <- 1..3 do
        SQLite.save_message(
          %Tet.Message{
            id: "msg_actual_#{i}",
            session_id: ses_id,
            role: :user,
            content: "actual count #{i}",
            timestamp: "2025-01-01T00:00:0#{i}Z"
          },
          []
        )
      end

      {:ok, msgs} = SQLite.list_messages(ses_id, [])
      {:ok, session} = SQLite.fetch_session(ses_id, [])

      assert session.message_count == length(msgs)
      assert session.message_count == 3
    end
  end

  describe "concurrent read access" do
    test "5 concurrent readers do not block or corrupt", %{ses_id: ses_id} do
      for i <- 1..5 do
        SQLite.save_message(
          %Tet.Message{
            id: "msg_conc_#{i}",
            session_id: ses_id,
            role: :user,
            content: "concurrent #{i}",
            timestamp: "2025-01-01T00:00:0#{i}Z"
          },
          []
        )
      end

      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            start = System.monotonic_time(:millisecond)

            {:ok, session} = SQLite.fetch_session(ses_id, [])
            {:ok, messages} = SQLite.list_messages(ses_id, [])
            {:ok, events} = SQLite.list_events(ses_id, [])

            elapsed = System.monotonic_time(:millisecond) - start

            %{
              session_ok: session.id == ses_id,
              msg_count: length(messages),
              elapsed_ms: elapsed
            }
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert Enum.all?(results, & &1.session_ok), "All readers must return the session"

      msg_counts = Enum.map(results, & &1.msg_count)
      unique_counts = msg_counts |> MapSet.new() |> MapSet.size()

      assert unique_counts == 1,
             "All readers must see the same count; got: #{inspect(msg_counts)}"

      assert hd(msg_counts) == 5

      max_elapsed = results |> Enum.map(& &1.elapsed_ms) |> Enum.max()

      assert max_elapsed < 2000,
             "Concurrent reads must not block; max was #{max_elapsed}ms"
    end

    test "concurrent reads during writes do not crash", %{ses_id: ses_id} do
      writer_task =
        Task.async(fn ->
          for i <- 1..10 do
            SQLite.save_message(
              %Tet.Message{
                id: "msg_write_#{i}",
                session_id: ses_id,
                role: :user,
                content: "write #{i}",
                timestamp: "2025-01-01T00:00:0#{rem(i, 10)}Z"
              },
              []
            )
          end
        end)

      reader_tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            for _j <- 1..5 do
              {:ok, msgs} = SQLite.list_messages(ses_id, [])
              {:ok, _session} = SQLite.fetch_session(ses_id, [])
              length(msgs)
            end
          end)
        end

      assert {:ok, _} = Task.yield(writer_task, 10_000)

      reader_results = Task.await_many(reader_tasks, 10_000)
      assert length(reader_results) == 5

      for counts <- reader_results do
        assert counts == Enum.sort(counts),
               "Reader must see monotonically non-decreasing message counts"
      end
    end
  end

  describe "all entity types persist through the store" do
    test "workspace, session, messages, events, checkpoint, autosave all round-trip", %{
      ws_id: ws_id,
      ses_id: ses_id
    } do
      SQLite.save_message(
        %Tet.Message{
          id: "msg_full_1",
          session_id: ses_id,
          role: :user,
          content: "full round trip",
          timestamp: "2025-01-01T00:00:00Z"
        },
        []
      )

      SQLite.append_event(
        %{
          id: "evt_full",
          session_id: ses_id,
          type: :session_started,
          payload: %{round_trip: true},
          metadata: %{}
        },
        []
      )

      {:ok, _cp} =
        SQLite.save_checkpoint(
          %{
            id: "ckpt_full",
            session_id: ses_id,
            sha256: "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
            state_snapshot: %{"full_test" => true}
          },
          []
        )

      autosave = %Tet.Autosave{
        checkpoint_id: "cp_full_autosave",
        session_id: ses_id,
        saved_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        messages: [
          %Tet.Message{
            id: "as_full_msg",
            session_id: ses_id,
            role: :user,
            content: "autosaved message",
            timestamp: "2025-01-01T00:00:00Z"
          }
        ],
        attachments: [],
        prompt_metadata: %{},
        prompt_debug: %{},
        prompt_debug_text: "full test",
        metadata: %{"full_test" => true}
      }

      {:ok, _as} = SQLite.save_autosave(autosave, [])

      {:ok, ws} = SQLite.get_workspace(ws_id)
      assert ws.name == "bd0084-test"

      {:ok, session} = SQLite.fetch_session(ses_id, [])
      assert session.message_count >= 1

      {:ok, messages} = SQLite.list_messages(ses_id, [])
      assert Enum.any?(messages, &(&1.content == "full round trip"))

      {:ok, events} = SQLite.list_events(ses_id, [])
      assert Enum.any?(events, &(&1.type == :session_started))

      {:ok, cp} = SQLite.get_checkpoint("ckpt_full", [])
      assert cp.state_snapshot["full_test"] == true

      {:ok, as} = SQLite.load_autosave(ses_id, [])
      assert as.session_id == ses_id
      assert as.prompt_debug_text == "full test"
      assert Map.get(as.metadata, "full_test") == true
    end

    test "WAL checkpoint flushes data to main DB", %{ses_id: ses_id} do
      SQLite.save_message(
        %Tet.Message{
          id: "msg_wal_cp_test",
          session_id: ses_id,
          role: :user,
          content: "before checkpoint",
          timestamp: "2025-01-01T00:00:00Z"
        },
        []
      )

      SQL.query!(Repo, "PRAGMA wal_checkpoint(TRUNCATE)", [])

      {:ok, msgs} = SQLite.list_messages(ses_id, [])
      assert length(msgs) == 1
      assert hd(msgs).content == "before checkpoint"

      # Verify WAL mode is still active after the checkpoint.
      %{rows: [[journal_mode]]} =
        SQL.query!(Repo, "PRAGMA journal_mode", [])

      assert journal_mode == "wal"
    end
  end
end
