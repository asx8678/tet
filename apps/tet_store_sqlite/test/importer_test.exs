defmodule Tet.Store.SQLite.ImporterTest do
  @moduledoc """
  Verifies the JSONL-to-SQLite importer for all entity types.

  Tests cover:
    1. All four JSONL entity types (messages, events, autosaves, prompt_history)
    2. Idempotency (SHA-256 hash tracking in legacy_jsonl_imports)
    3. Malformed data handling (skip + warn, never crash)
    4. legacy_jsonl_imports tracking table correctness
    5. import_file for individual files
    6. import_all orchestration
    7. Force re-import flag (changed content)
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Tet.Store.SQLite.Importer
  alias Tet.Store.SQLite.Repo

  @cleanup_tables [
    "legacy_jsonl_imports",
    "messages",
    "autosaves",
    "prompt_history_entries",
    "events",
    "sessions",
    "workspaces"
  ]

  setup do
    for table <- @cleanup_tables do
      SQL.query!(Repo, "DELETE FROM #{table}", [])
    end

    tet_dir =
      Path.join(System.tmp_dir!(), "tet_importer_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tet_dir)

    on_exit(fn -> File.rm_rf!(tet_dir) end)

    {:ok, tet_dir: tet_dir}
  end

  # ══════════════════════════════════════════════════════════════════
  # Helpers: build valid JSONL fixture content for each entity type
  # ══════════════════════════════════════════════════════════════════

  defp message_jsonl(session_id \\ "ses_import_001") do
    Enum.map_join(1..5, "\n", fn i ->
      Jason.encode!(%{
        "id" => "msg_import_#{session_id}_#{i}",
        "session_id" => session_id,
        "role" => if(rem(i, 2) == 0, do: "assistant", else: "user"),
        "content" => "Hello message #{i}",
        "created_at" => "2025-01-01T00:00:#{String.pad_leading(Integer.to_string(i), 2, "0")}Z"
      })
    end)
  end

  defp event_jsonl(session_id \\ "ses_import_001") do
    Enum.map_join(1..3, "\n", fn i ->
      Jason.encode!(%{
        "type" => "session.created",
        "session_id" => session_id,
        "payload" => %{"index" => i},
        "metadata" => %{},
        "created_at" => "2025-01-01T00:00:#{String.pad_leading(Integer.to_string(i), 2, "0")}Z"
      })
    end)
  end

  defp autosave_jsonl(session_id \\ "ses_import_001") do
    Jason.encode!(%{
      "checkpoint_id" => "cp_import_001",
      "session_id" => session_id,
      "saved_at" => "2025-01-01T00:05:00Z",
      "messages" => [
        %{
          "id" => "msg_autosave_001",
          "session_id" => session_id,
          "role" => "user",
          "content" => "autosave content",
          "created_at" => "2025-01-01T00:04:00Z"
        }
      ],
      "metadata" => %{}
    })
  end

  defp prompt_history_jsonl do
    original_prompt = "Implement a login page"
    refined_prompt = "Create a responsive login page with form validation"
    sha_original = Tet.Prompt.Canonical.sha256(original_prompt)
    sha_refined = Tet.Prompt.Canonical.sha256(refined_prompt)

    Jason.encode!(%{
      "id" => "prompt-history-import-001",
      "created_at" => "2025-01-01T00:00:00Z",
      "request" => %{
        "prompt" => original_prompt,
        "preset_id" => "coding"
      },
      "result" => %{
        "id" => "prompt-refinement-import-001",
        "preset_id" => "coding",
        "preset_version" => "tet.prompt_lab.preset.v1",
        "status" => "improved",
        "original_prompt" => original_prompt,
        "refined_prompt" => refined_prompt,
        "summary" => "Improved specificity and added validation requirement",
        "scores_before" => %{
          "clarity" => %{"score" => 5, "comment" => "Vague requirements"}
        },
        "scores_after" => %{
          "clarity" => %{"score" => 8, "comment" => "Clear and actionable"}
        },
        "original_sha256" => sha_original,
        "refined_sha256" => sha_refined
      },
      "metadata" => %{}
    })
  end

  # ══════════════════════════════════════════════════════════════════
  # 1. import_file: each entity type individually
  # ══════════════════════════════════════════════════════════════════

  describe "import_file/3 — messages" do
    test "imports messages into SQLite with correct row count", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "messages.jsonl")
      File.write!(path, message_jsonl())

      assert {:ok, 5} = Importer.import_file(:messages, path)

      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM messages", [])

      assert count == 5

      # Session should have been derived from messages
      %{rows: [[ses_count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM sessions", [])

      assert ses_count >= 1
    end
  end

  describe "import_file/3 — events" do
    test "imports events into SQLite with correct row count", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "events.jsonl")
      File.write!(path, event_jsonl())

      assert {:ok, 3} = Importer.import_file(:events, path)

      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM events", [])

      assert count == 3
    end
  end

  describe "import_file/3 — autosaves" do
    test "imports autosaves into SQLite with correct row count", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "autosaves.jsonl")
      File.write!(path, autosave_jsonl())

      assert {:ok, 1} = Importer.import_file(:autosaves, path)

      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM autosaves", [])

      assert count == 1
    end
  end

  describe "import_file/3 — prompt_history" do
    test "imports prompt history into SQLite with correct row count", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "prompt_history.jsonl")
      File.write!(path, prompt_history_jsonl())

      assert {:ok, 1} = Importer.import_file(:prompt_history, path)

      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM prompt_history_entries", [])

      assert count == 1
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # 2. import_all: orchestrates all four file types
  # ══════════════════════════════════════════════════════════════════

  describe "import_all/2" do
    test "imports all four entity types and returns per-kind counts", %{tet_dir: tet_dir} do
      File.write!(Path.join(tet_dir, "messages.jsonl"), message_jsonl())
      File.write!(Path.join(tet_dir, "events.jsonl"), event_jsonl())
      File.write!(Path.join(tet_dir, "autosaves.jsonl"), autosave_jsonl())
      File.write!(Path.join(tet_dir, "prompt_history.jsonl"), prompt_history_jsonl())

      assert {:ok, result} = Importer.import_all(tet_dir)

      assert result.messages == 5
      assert result.events == 3
      assert result.autosaves == 1
      assert result.prompt_history == 1
    end

    test "handles missing files gracefully (returns 0)", %{tet_dir: tet_dir} do
      assert {:ok, result} = Importer.import_all(tet_dir)

      assert result.messages == 0
      assert result.events == 0
      assert result.autosaves == 0
      assert result.prompt_history == 0
    end

    test "handles partial files — only writes what exists", %{tet_dir: tet_dir} do
      File.write!(Path.join(tet_dir, "messages.jsonl"), message_jsonl())

      assert {:ok, result} = Importer.import_all(tet_dir)

      assert result.messages == 5
      assert result.events == 0
      assert result.autosaves == 0
      assert result.prompt_history == 0
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # 3. Idempotency: re-running import produces no new rows
  # ══════════════════════════════════════════════════════════════════

  describe "idempotency" do
    test "import_file twice with same content returns :already_imported", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "messages.jsonl")
      File.write!(path, message_jsonl())

      assert {:ok, 5} = Importer.import_file(:messages, path)

      %{rows: [[count_after_first]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM messages", [])

      assert count_after_first == 5

      assert {:error, :already_imported} = Importer.import_file(:messages, path)

      %{rows: [[count_after_second]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM messages", [])

      assert count_after_second == 5, "idempotency violation: row count changed on re-import"
    end

    test "import_all twice returns :skipped for already-imported kinds", %{tet_dir: tet_dir} do
      File.write!(Path.join(tet_dir, "messages.jsonl"), message_jsonl())
      File.write!(Path.join(tet_dir, "events.jsonl"), event_jsonl())

      assert {:ok, first} = Importer.import_all(tet_dir)
      assert first.messages == 5
      assert first.events == 3

      assert {:ok, second} = Importer.import_all(tet_dir)
      assert second.messages == :skipped
      assert second.events == :skipped
    end

    test "force: true re-imports when file content has changed", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "events.jsonl")
      File.write!(path, event_jsonl())

      assert {:ok, 3} = Importer.import_file(:events, path)
      assert {:error, :already_imported} = Importer.import_file(:events, path)

      # Change the file content (different SHA-256) — force should now work
      File.write!(path, event_jsonl("ses_changed"))

      # Without force: returns :file_changed_since_last_import error
      assert {:error, {:file_changed_since_last_import, :events, _}} =
               Importer.import_file(:events, path)

      # With force: re-imports successfully
      assert {:ok, 3} = Importer.import_file(:events, path, force: true)
    end

    test "force: true with unchanged file still returns :already_imported", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "messages.jsonl")
      File.write!(path, message_jsonl())

      assert {:ok, 5} = Importer.import_file(:messages, path)

      # Same content, same hash — force flag is irrelevant
      assert {:error, :already_imported} = Importer.import_file(:messages, path, force: true)
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # 4. Malformed data handling
  # ══════════════════════════════════════════════════════════════════

  describe "malformed data" do
    test "corrupt JSONL lines are skipped with warnings, not crashes", %{tet_dir: tet_dir} do
      valid_msg_a =
        Jason.encode!(%{
          "id" => "msg_valid_a",
          "session_id" => "ses_malformed_001",
          "role" => "user",
          "content" => "valid message A",
          "created_at" => "2025-01-01T00:00:00Z"
        })

      valid_msg_b =
        Jason.encode!(%{
          "id" => "msg_valid_b",
          "session_id" => "ses_malformed_001",
          "role" => "assistant",
          "content" => "valid message B",
          "created_at" => "2025-01-01T00:01:00Z"
        })

      content =
        Enum.join(
          [
            "THIS IS NOT JSON AT ALL",
            valid_msg_a,
            ~s({"id": "msg_partial),
            valid_msg_b,
            "   ",
            ~s({"role": "user", "content": "missing session_id"})
          ],
          "\n"
        )

      path = Path.join(tet_dir, "messages.jsonl")
      File.write!(path, content)

      # 2 valid lines parsed → {:ok, 2}. Corrupt lines skipped silently.
      assert {:ok, 2} = Importer.import_file(:messages, path)

      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM messages", [])

      assert count == 2
    end

    test "empty JSONL file imports zero rows", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "messages.jsonl")
      File.write!(path, "")

      assert {:ok, 0} = Importer.import_file(:messages, path)

      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM messages", [])

      assert count == 0
    end

    test "events with valid JSON but invalid from_map are skipped gracefully", %{tet_dir: tet_dir} do
      content =
        Enum.join(
          [
            Jason.encode!(%{
              "type" => "session.created",
              "session_id" => "ses_evt_bad",
              "created_at" => "2025-01-01T00:00:00Z"
            }),
            # Missing required 'type' — should fail from_map
            Jason.encode!(%{"session_id" => "ses_evt_bad", "payload" => %{}}),
            # Valid event
            Jason.encode!(%{
              "type" => "session.created",
              "session_id" => "ses_evt_bad",
              "payload" => %{},
              "metadata" => %{},
              "created_at" => "2025-01-01T00:01:00Z"
            })
          ],
          "\n"
        )

      path = Path.join(tet_dir, "events.jsonl")
      File.write!(path, content)

      assert {:ok, count} = Importer.import_file(:events, path)
      assert count >= 1
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # 5. legacy_jsonl_imports tracking table
  # ══════════════════════════════════════════════════════════════════

  describe "legacy_jsonl_imports tracking" do
    test "records each imported file with correct metadata", %{tet_dir: tet_dir} do
      msg_path = Path.join(tet_dir, "messages.jsonl")
      evt_path = Path.join(tet_dir, "events.jsonl")
      File.write!(msg_path, message_jsonl())
      File.write!(evt_path, event_jsonl())

      assert {:ok, 5} = Importer.import_file(:messages, msg_path)
      assert {:ok, 3} = Importer.import_file(:events, evt_path)

      %{rows: rows} =
        SQL.query!(
          Repo,
          """
            SELECT source_kind, source_path, sha256, row_count, source_size
            FROM legacy_jsonl_imports
            ORDER BY source_kind
          """,
          []
        )

      assert length(rows) == 2

      kinds = Enum.map(rows, &hd/1) |> Enum.sort()
      assert kinds == ["events", "messages"]

      for row <- rows do
        [_kind, _path, sha256, count, size] = row
        assert is_binary(sha256)
        assert String.length(sha256) == 64
        assert count > 0
        assert size > 0
      end
    end

    test "tracks import_all as separate records per kind", %{tet_dir: tet_dir} do
      File.write!(Path.join(tet_dir, "messages.jsonl"), message_jsonl())
      File.write!(Path.join(tet_dir, "autosaves.jsonl"), autosave_jsonl())
      File.write!(Path.join(tet_dir, "prompt_history.jsonl"), prompt_history_jsonl())

      assert {:ok, _} = Importer.import_all(tet_dir)

      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM legacy_jsonl_imports", [])

      assert count == 3
    end

    test "no tracking record for missing files", %{tet_dir: tet_dir} do
      assert {:ok, _} = Importer.import_all(tet_dir)

      %{rows: [[count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM legacy_jsonl_imports", [])

      assert count == 0
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # 6. Cross-cutting: session and workspace creation
  # ══════════════════════════════════════════════════════════════════

  describe "import side effects" do
    test "creates default workspace", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "messages.jsonl")
      File.write!(path, message_jsonl())

      assert {:ok, _} = Importer.import_file(:messages, path)

      %{rows: [[ws_count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM workspaces WHERE name = 'legacy-import'", [])

      assert ws_count == 1
    end

    test "creates sessions from messages", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "messages.jsonl")
      File.write!(path, message_jsonl("ses_multi_msg"))

      assert {:ok, _} = Importer.import_file(:messages, path)

      %{rows: [[ses_count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM sessions WHERE id = 'ses_multi_msg'", [])

      assert ses_count == 1
    end

    test "events for a new session auto-create minimal session shell", %{tet_dir: tet_dir} do
      path = Path.join(tet_dir, "events.jsonl")
      File.write!(path, event_jsonl("ses_evt_shell"))

      assert {:ok, 3} = Importer.import_file(:events, path)

      %{rows: [[ses_count]]} =
        SQL.query!(Repo, "SELECT COUNT(*) FROM sessions WHERE id = 'ses_evt_shell'", [])

      assert ses_count == 1
    end
  end
end
