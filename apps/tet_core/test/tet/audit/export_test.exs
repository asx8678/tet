defmodule Tet.Audit.ExportTest do
  use ExUnit.Case, async: true

  alias Tet.Audit
  alias Tet.Audit.Export

  defp make_entry(overrides) do
    defaults = %{
      id: Audit.generate_id(),
      timestamp: ~U[2025-05-01 12:00:00Z],
      event_type: :tool_call,
      action: :execute,
      actor: :agent,
      session_id: "ses_export",
      resource: "/lib/foo.ex",
      outcome: :success,
      metadata: %{}
    }

    {:ok, entry} = Audit.new(Map.merge(defaults, overrides))
    entry
  end

  describe "to_jsonl/2" do
    test "exports entries as JSONL with one JSON object per line" do
      e1 = make_entry(%{id: "aud_j1"})
      e2 = make_entry(%{id: "aud_j2"})

      assert {:ok, jsonl} = Export.to_jsonl([e1, e2])
      lines = String.split(jsonl, "\n", trim: true)

      assert length(lines) == 2
      assert Enum.all?(lines, fn line -> match?({:ok, _}, Jason.decode(line)) end)
    end

    test "each line contains the entry data" do
      e = make_entry(%{id: "aud_data", resource: "/lib/bar.ex"})

      assert {:ok, jsonl} = Export.to_jsonl([e])
      {:ok, parsed} = jsonl |> String.trim() |> Jason.decode()

      assert parsed["id"] == "aud_data"
      assert parsed["resource"] == "/lib/bar.ex"
      assert parsed["event_type"] == "tool_call"
    end

    test "returns empty string for empty list" do
      assert {:ok, ""} = Export.to_jsonl([])
    end

    test "redacts sensitive metadata before export" do
      e = make_entry(%{id: "aud_rdct", metadata: %{api_key: "sk-secret-key"}})

      assert {:ok, jsonl} = Export.to_jsonl([e])
      {:ok, parsed} = jsonl |> String.trim() |> Jason.decode()

      assert parsed["metadata"]["api_key"] == "[REDACTED]"
    end

    test "JSONL ends with a trailing newline" do
      e = make_entry(%{id: "aud_nl"})
      assert {:ok, jsonl} = Export.to_jsonl([e])
      assert String.ends_with?(jsonl, "\n")
    end
  end

  describe "from_jsonl/1" do
    test "parses valid JSONL back to audit entries" do
      e1 = make_entry(%{id: "aud_parse1"})
      e2 = make_entry(%{id: "aud_parse2"})

      {:ok, jsonl} = Export.to_jsonl([e1, e2])
      assert {:ok, entries} = Export.from_jsonl(jsonl)

      assert length(entries) == 2
      assert Enum.map(entries, & &1.id) == ["aud_parse1", "aud_parse2"]
    end

    test "skips invalid lines" do
      jsonl = """
      {"id":"aud_ok","event_type":"error","action":"create","actor":"system","timestamp":"2025-05-01T12:00:00Z"}
      this is not json
      {"id":"aud_ok2","event_type":"message","action":"create","actor":"user","timestamp":"2025-05-01T12:00:00Z"}
      """

      assert {:ok, entries} = Export.from_jsonl(jsonl)
      assert length(entries) == 2
    end

    test "returns empty list for empty string" do
      assert {:ok, []} = Export.from_jsonl("")
    end

    test "returns empty list for all-invalid lines" do
      assert {:ok, []} = Export.from_jsonl("nope\nalso nope\n")
    end
  end

  describe "round-trip: export → parse → matches original" do
    test "entries survive the round-trip" do
      entries =
        for i <- 1..3 do
          make_entry(%{
            id: "aud_trip_#{i}",
            event_type: Enum.at([:tool_call, :message, :error], i - 1),
            session_id: "ses_trip"
          })
        end

      {:ok, jsonl} = Export.to_jsonl(entries)
      {:ok, restored} = Export.from_jsonl(jsonl)

      assert length(restored) == 3

      for {orig, rest} <- Enum.zip(entries, restored) do
        assert rest.id == orig.id
        assert rest.timestamp == orig.timestamp
        assert rest.session_id == orig.session_id
        assert rest.event_type == orig.event_type
        assert rest.action == orig.action
        assert rest.actor == orig.actor
        assert rest.resource == orig.resource
        assert rest.outcome == orig.outcome
      end
    end
  end

  describe "to_file/3" do
    test "writes JSONL to a file in append-only mode" do
      path =
        Path.join(
          System.tmp_dir!(),
          "audit_export_test_#{System.unique_integer([:positive])}.jsonl"
        )

      on_exit(fn -> File.rm(path) end)

      e1 = make_entry(%{id: "aud_file1"})
      e2 = make_entry(%{id: "aud_file2"})

      assert :ok = Export.to_file([e1], path)
      assert :ok = Export.to_file([e2], path)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 2
    end

    test "creates file if it does not exist" do
      path =
        Path.join(System.tmp_dir!(), "audit_new_file_#{System.unique_integer([:positive])}.jsonl")

      on_exit(fn -> File.rm(path) end)

      refute File.exists?(path)
      assert :ok = Export.to_file([make_entry(%{id: "aud_new"})], path)
      assert File.exists?(path)
    end

    test "no-ops for empty list" do
      path =
        Path.join(System.tmp_dir!(), "audit_empty_#{System.unique_integer([:positive])}.jsonl")

      assert :ok = Export.to_file([], path)
      refute File.exists?(path)
    end

    test "redacts metadata in file output" do
      path =
        Path.join(System.tmp_dir!(), "audit_redact_#{System.unique_integer([:positive])}.jsonl")

      on_exit(fn -> File.rm(path) end)

      e = make_entry(%{id: "aud_fredact", metadata: %{secret_key: "shhh"}})
      assert :ok = Export.to_file([e], path)

      {:ok, content} = File.read(path)
      assert String.contains?(content, "[REDACTED]")
      refute String.contains?(content, "shhh")
    end
  end
end
