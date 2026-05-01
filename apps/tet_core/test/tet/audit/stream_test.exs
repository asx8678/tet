defmodule Tet.Audit.StreamTest do
  use ExUnit.Case, async: true

  alias Tet.Audit
  alias Tet.Audit.Stream

  # Each test gets a unique GenServer to avoid conflicts in async tests.
  defp start_stream do
    name = :"stream_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = Stream.start_link(name: name)
    pid
  end

  defp make_entry(overrides) do
    defaults = %{
      id: Audit.generate_id(),
      timestamp: DateTime.utc_now(),
      event_type: :tool_call,
      action: :execute,
      actor: :agent,
      session_id: "ses_default",
      resource: "/lib/foo.ex",
      outcome: :success,
      metadata: %{}
    }

    {:ok, entry} = Audit.new(Map.merge(defaults, overrides))
    entry
  end

  describe "start_link/1 and count/1" do
    test "creates an empty stream" do
      pid = start_stream()
      assert Stream.count(pid) == 0
    end
  end

  describe "append/2" do
    test "appends a valid audit entry" do
      pid = start_stream()
      entry = make_entry(%{id: "aud_append_1"})

      assert {:ok, ^entry} = Stream.append(pid, entry)
      assert Stream.count(pid) == 1
    end

    test "rejects duplicate IDs" do
      pid = start_stream()
      entry = make_entry(%{id: "aud_dup"})

      assert {:ok, _} = Stream.append(pid, entry)
      assert {:error, :duplicate_id} = Stream.append(pid, entry)
      assert Stream.count(pid) == 1
    end

    test "rejects non-audit-entry values" do
      pid = start_stream()
      assert {:error, :invalid_audit_entry} = Stream.append(pid, %{not: "an audit"})
      assert {:error, :invalid_audit_entry} = Stream.append(pid, "nope")
    end

    test "multiple entries accumulate" do
      pid = start_stream()

      for i <- 1..5 do
        entry = make_entry(%{id: "aud_multi_#{i}"})
        assert {:ok, _} = Stream.append(pid, entry)
      end

      assert Stream.count(pid) == 5
    end
  end

  describe "append-only invariant" do
    test "no update function is exposed" do
      refute function_exported?(Stream, :update, 2)
      refute function_exported?(Stream, :update, 3)
    end

    test "no delete function is exposed" do
      refute function_exported?(Stream, :delete, 1)
      refute function_exported?(Stream, :delete, 2)
    end

    test "no terminate function is exposed" do
      refute function_exported?(Stream, :terminate, 1)
    end

    test "ETS table is protected — direct mutation from outside is impossible" do
      pid = start_stream()
      entry = make_entry(%{id: "aud_legit"})
      Stream.append(pid, entry)

      # Grab the internal table ref via :sys introspection
      %{table: table} = :sys.get_state(pid)

      # External process cannot insert — :protected blocks writes from non-owner
      assert_raise ArgumentError, fn ->
        :ets.insert(table, {"sneaky_id", DateTime.utc_now(), %{}})
      end

      # External process cannot delete rows
      assert_raise ArgumentError, fn ->
        :ets.delete(table, "aud_legit")
      end

      # External process cannot delete the whole table
      assert_raise ArgumentError, fn ->
        :ets.delete(table)
      end

      # Stream contents remain untampered
      assert Stream.count(pid) == 1
    end
  end

  describe "query/2" do
    test "returns all entries with empty filters" do
      pid = start_stream()
      e1 = make_entry(%{id: "aud_q1"})
      e2 = make_entry(%{id: "aud_q2"})
      Stream.append(pid, e1)
      Stream.append(pid, e2)

      assert {:ok, entries} = Stream.query(pid)
      assert length(entries) == 2
    end

    test "filters by session_id" do
      pid = start_stream()
      e1 = make_entry(%{id: "aud_s1", session_id: "ses_a"})
      e2 = make_entry(%{id: "aud_s2", session_id: "ses_b"})
      e3 = make_entry(%{id: "aud_s3", session_id: "ses_a"})
      Stream.append(pid, e1)
      Stream.append(pid, e2)
      Stream.append(pid, e3)

      assert {:ok, entries} = Stream.query(pid, session_id: "ses_a")
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.session_id == "ses_a"))
    end

    test "filters by event_type" do
      pid = start_stream()
      e1 = make_entry(%{id: "aud_et1", event_type: :tool_call})
      e2 = make_entry(%{id: "aud_et2", event_type: :error})
      e3 = make_entry(%{id: "aud_et3", event_type: :tool_call})
      Stream.append(pid, e1)
      Stream.append(pid, e2)
      Stream.append(pid, e3)

      assert {:ok, entries} = Stream.query(pid, event_type: :tool_call)
      assert length(entries) == 2
    end

    test "filters by actor" do
      pid = start_stream()
      e1 = make_entry(%{id: "aud_a1", actor: :user})
      e2 = make_entry(%{id: "aud_a2", actor: :agent})
      Stream.append(pid, e1)
      Stream.append(pid, e2)

      assert {:ok, entries} = Stream.query(pid, actor: :user)
      assert length(entries) == 1
      assert hd(entries).actor == :user
    end

    test "filters by time range" do
      pid = start_stream()
      t1 = ~U[2025-05-01 10:00:00Z]
      t2 = ~U[2025-05-01 12:00:00Z]
      t3 = ~U[2025-05-01 14:00:00Z]

      e1 = make_entry(%{id: "aud_t1", timestamp: t1})
      e2 = make_entry(%{id: "aud_t2", timestamp: t2})
      e3 = make_entry(%{id: "aud_t3", timestamp: t3})
      Stream.append(pid, e1)
      Stream.append(pid, e2)
      Stream.append(pid, e3)

      assert {:ok, entries} = Stream.query(pid, from: ~U[2025-05-01 11:00:00Z])
      assert length(entries) == 2

      assert {:ok, entries} = Stream.query(pid, to: ~U[2025-05-01 13:00:00Z])
      assert length(entries) == 2

      assert {:ok, entries} =
               Stream.query(pid,
                 from: ~U[2025-05-01 11:00:00Z],
                 to: ~U[2025-05-01 13:00:00Z]
               )

      assert length(entries) == 1
      assert hd(entries).id == "aud_t2"
    end

    test "combined filters narrow results" do
      pid = start_stream()
      e1 = make_entry(%{id: "aud_c1", session_id: "ses_x", actor: :user})
      e2 = make_entry(%{id: "aud_c2", session_id: "ses_x", actor: :agent})
      e3 = make_entry(%{id: "aud_c3", session_id: "ses_y", actor: :user})
      Stream.append(pid, e1)
      Stream.append(pid, e2)
      Stream.append(pid, e3)

      assert {:ok, entries} = Stream.query(pid, session_id: "ses_x", actor: :user)
      assert length(entries) == 1
      assert hd(entries).id == "aud_c1"
    end

    test "returns entries sorted by timestamp ascending" do
      pid = start_stream()
      t1 = ~U[2025-05-01 14:00:00Z]
      t2 = ~U[2025-05-01 10:00:00Z]
      t3 = ~U[2025-05-01 12:00:00Z]

      Stream.append(pid, make_entry(%{id: "aud_ord1", timestamp: t1}))
      Stream.append(pid, make_entry(%{id: "aud_ord2", timestamp: t2}))
      Stream.append(pid, make_entry(%{id: "aud_ord3", timestamp: t3}))

      assert {:ok, entries} = Stream.query(pid)
      timestamps = Enum.map(entries, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, DateTime)
    end
  end

  describe "export/2" do
    test "exports entries as JSONL" do
      pid = start_stream()
      Stream.append(pid, make_entry(%{id: "aud_exp1"}))
      Stream.append(pid, make_entry(%{id: "aud_exp2"}))

      assert {:ok, jsonl} = Stream.export(pid)
      lines = String.split(jsonl, "\n", trim: true)
      assert length(lines) == 2
    end

    test "exports with filters" do
      pid = start_stream()
      Stream.append(pid, make_entry(%{id: "aud_ef1", session_id: "ses_a"}))
      Stream.append(pid, make_entry(%{id: "aud_ef2", session_id: "ses_b"}))

      assert {:ok, jsonl} = Stream.export(pid, session_id: "ses_a")
      lines = String.split(jsonl, "\n", trim: true)
      assert length(lines) == 1
    end
  end

  describe "GenServer lifecycle" do
    test "ETS table is cleaned up when GenServer stops" do
      pid = start_stream()
      %{table: table} = :sys.get_state(pid)

      # Table exists while GenServer is alive
      assert :ets.info(table) != :undefined

      GenServer.stop(pid)

      # Table is gone after GenServer stops
      assert :ets.info(table) == :undefined
    end
  end
end
