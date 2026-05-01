defmodule Tet.Audit.StreamTest do
  use ExUnit.Case, async: true

  alias Tet.Audit
  alias Tet.Audit.Stream

  # Each test gets a unique ETS table name to avoid conflicts in async tests.
  defp unique_stream do
    name = :"stream_test_#{System.unique_integer([:positive])}"
    Stream.init(name)
    name
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

  describe "init/1 and count/1" do
    test "creates an empty stream" do
      name = unique_stream()
      assert Stream.count(name) == 0
    end
  end

  describe "append/2" do
    test "appends a valid audit entry" do
      name = unique_stream()
      entry = make_entry(%{id: "aud_append_1"})

      assert {:ok, ^entry} = Stream.append(name, entry)
      assert Stream.count(name) == 1
    end

    test "rejects duplicate IDs" do
      name = unique_stream()
      entry = make_entry(%{id: "aud_dup"})

      assert {:ok, _} = Stream.append(name, entry)
      assert {:error, :duplicate_id} = Stream.append(name, entry)
      assert Stream.count(name) == 1
    end

    test "rejects non-audit-entry values" do
      name = unique_stream()
      assert {:error, :invalid_audit_entry} = Stream.append(name, %{not: "an audit"})
      assert {:error, :invalid_audit_entry} = Stream.append(name, "nope")
    end

    test "multiple entries accumulate" do
      name = unique_stream()

      for i <- 1..5 do
        entry = make_entry(%{id: "aud_multi_#{i}"})
        assert {:ok, _} = Stream.append(name, entry)
      end

      assert Stream.count(name) == 5
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
  end

  describe "query/2" do
    test "returns all entries with empty filters" do
      name = unique_stream()
      e1 = make_entry(%{id: "aud_q1"})
      e2 = make_entry(%{id: "aud_q2"})
      Stream.append(name, e1)
      Stream.append(name, e2)

      assert {:ok, entries} = Stream.query(name)
      assert length(entries) == 2
    end

    test "filters by session_id" do
      name = unique_stream()
      e1 = make_entry(%{id: "aud_s1", session_id: "ses_a"})
      e2 = make_entry(%{id: "aud_s2", session_id: "ses_b"})
      e3 = make_entry(%{id: "aud_s3", session_id: "ses_a"})
      Stream.append(name, e1)
      Stream.append(name, e2)
      Stream.append(name, e3)

      assert {:ok, entries} = Stream.query(name, session_id: "ses_a")
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.session_id == "ses_a"))
    end

    test "filters by event_type" do
      name = unique_stream()
      e1 = make_entry(%{id: "aud_et1", event_type: :tool_call})
      e2 = make_entry(%{id: "aud_et2", event_type: :error})
      e3 = make_entry(%{id: "aud_et3", event_type: :tool_call})
      Stream.append(name, e1)
      Stream.append(name, e2)
      Stream.append(name, e3)

      assert {:ok, entries} = Stream.query(name, event_type: :tool_call)
      assert length(entries) == 2
    end

    test "filters by actor" do
      name = unique_stream()
      e1 = make_entry(%{id: "aud_a1", actor: :user})
      e2 = make_entry(%{id: "aud_a2", actor: :agent})
      Stream.append(name, e1)
      Stream.append(name, e2)

      assert {:ok, entries} = Stream.query(name, actor: :user)
      assert length(entries) == 1
      assert hd(entries).actor == :user
    end

    test "filters by time range" do
      name = unique_stream()
      t1 = ~U[2025-05-01 10:00:00Z]
      t2 = ~U[2025-05-01 12:00:00Z]
      t3 = ~U[2025-05-01 14:00:00Z]

      e1 = make_entry(%{id: "aud_t1", timestamp: t1})
      e2 = make_entry(%{id: "aud_t2", timestamp: t2})
      e3 = make_entry(%{id: "aud_t3", timestamp: t3})
      Stream.append(name, e1)
      Stream.append(name, e2)
      Stream.append(name, e3)

      assert {:ok, entries} = Stream.query(name, from: ~U[2025-05-01 11:00:00Z])
      assert length(entries) == 2

      assert {:ok, entries} = Stream.query(name, to: ~U[2025-05-01 13:00:00Z])
      assert length(entries) == 2

      assert {:ok, entries} =
               Stream.query(name,
                 from: ~U[2025-05-01 11:00:00Z],
                 to: ~U[2025-05-01 13:00:00Z]
               )

      assert length(entries) == 1
      assert hd(entries).id == "aud_t2"
    end

    test "combined filters narrow results" do
      name = unique_stream()
      e1 = make_entry(%{id: "aud_c1", session_id: "ses_x", actor: :user})
      e2 = make_entry(%{id: "aud_c2", session_id: "ses_x", actor: :agent})
      e3 = make_entry(%{id: "aud_c3", session_id: "ses_y", actor: :user})
      Stream.append(name, e1)
      Stream.append(name, e2)
      Stream.append(name, e3)

      assert {:ok, entries} = Stream.query(name, session_id: "ses_x", actor: :user)
      assert length(entries) == 1
      assert hd(entries).id == "aud_c1"
    end

    test "returns entries sorted by timestamp ascending" do
      name = unique_stream()
      t1 = ~U[2025-05-01 14:00:00Z]
      t2 = ~U[2025-05-01 10:00:00Z]
      t3 = ~U[2025-05-01 12:00:00Z]

      Stream.append(name, make_entry(%{id: "aud_ord1", timestamp: t1}))
      Stream.append(name, make_entry(%{id: "aud_ord2", timestamp: t2}))
      Stream.append(name, make_entry(%{id: "aud_ord3", timestamp: t3}))

      assert {:ok, entries} = Stream.query(name)
      timestamps = Enum.map(entries, & &1.timestamp)
      assert timestamps == Enum.sort(timestamps, DateTime)
    end
  end

  describe "export/2" do
    test "exports entries as JSONL" do
      name = unique_stream()
      Stream.append(name, make_entry(%{id: "aud_exp1"}))
      Stream.append(name, make_entry(%{id: "aud_exp2"}))

      assert {:ok, jsonl} = Stream.export(name)
      lines = String.split(jsonl, "\n", trim: true)
      assert length(lines) == 2
    end

    test "exports with filters" do
      name = unique_stream()
      Stream.append(name, make_entry(%{id: "aud_ef1", session_id: "ses_a"}))
      Stream.append(name, make_entry(%{id: "aud_ef2", session_id: "ses_b"}))

      assert {:ok, jsonl} = Stream.export(name, session_id: "ses_a")
      lines = String.split(jsonl, "\n", trim: true)
      assert length(lines) == 1
    end
  end

  describe "terminate/1" do
    test "tears down the stream" do
      name = unique_stream()
      Stream.append(name, make_entry(%{id: "aud_term"}))
      assert Stream.count(name) == 1

      assert :ok = Stream.terminate(name)
      assert :undefined == :ets.info(name)
    end
  end
end
