defmodule Tet.AutosaveRestoreTest do
  use ExUnit.Case, async: false

  setup do
    # Clean tables for test isolation
    alias Tet.Store.SQLite.Repo

    for table <- ["events", "messages", "autosaves", "sessions", "workspaces"] do
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table}", [])
    end

    :ok
  end

  test "autosaves and restores a session with attachments and prompt debug metadata" do
    session_id = unique_session("fixture")

    assert {:ok, ask_result} =
             Tet.ask("fixture turn",
               provider: :mock,
               session_id: session_id
             )

    assert ask_result.session_id == session_id

    assert {:ok, first} =
             Tet.autosave_session(session_id, prompt_attrs("req-1"),
               checkpoint_id: "checkpoint-old",
               saved_at: "2025-01-01T00:00:00.000Z",
               autosave_metadata: %{fixture: "old"}
             )

    assert {:ok, second} =
             Tet.autosave_session(session_id, prompt_attrs("req-2"),
               checkpoint_id: "checkpoint-new",
               saved_at: "2025-01-01T00:00:01.000Z",
               autosave_metadata: %{fixture: "new"}
             )

    assert {:ok, [listed_new, listed_old]} = Tet.list_autosaves()
    assert listed_new.checkpoint_id == "checkpoint-new"
    assert listed_old.checkpoint_id == "checkpoint-old"

    assert {:ok, restored} = Tet.restore_autosave(session_id)

    assert restored.checkpoint_id == second.checkpoint_id
    assert restored.saved_at == "2025-01-01T00:00:01.000Z"
    assert restored.messages == second.messages
    assert Enum.map(restored.messages, & &1.role) == [:user, :assistant]
    assert Enum.map(restored.messages, & &1.content) == ["fixture turn", "mock: fixture turn"]

    assert restored.attachments == second.attachments

    assert restored.attachments == [
             %{
               "byte_size" => 128,
               "id" => "attachment-fixture",
               "media_type" => "text/markdown",
               "metadata" => %{"label" => "restore-fixture"},
               "name" => "design-notes.md",
               "sha256" => String.duplicate("b", 64),
               "source" => "fixture"
             }
           ]

    assert restored.prompt_metadata == %{"request_id" => "req-2", "suite" => "autosave"}
    assert restored.prompt_debug == second.prompt_debug
    assert restored.prompt_debug_text == second.prompt_debug_text
    assert restored.prompt_debug["metadata"] == %{"request_id" => "req-2", "suite" => "autosave"}

    attachment_layer =
      Enum.find(restored.prompt_debug["layers"], &(&1["kind"] == "attachment_metadata"))

    assert attachment_layer["metadata"]["attachment_count"] == 1
    assert attachment_layer["metadata"]["attachments"] == restored.attachments
    assert restored.metadata == %{"fixture" => "new"}
    assert first.prompt_metadata == %{"request_id" => "req-1", "suite" => "autosave"}
  end

  test "runtime compacts persisted context and autosave records compaction metadata" do
    session_id = unique_session("compact")

    for prompt <- ["first", "second", "third"] do
      assert {:ok, _result} =
               Tet.ask(prompt,
                 provider: :mock,
                 session_id: session_id
               )
    end

    assert {:ok, context} =
             Tet.compact_context(session_id,
               force: true,
               recent_count: 2,
               strategy: :autosave_summary
             )

    assert context.changed?

    assert Enum.map(context.compacted_messages, & &1.content) == [
             "first",
             "mock: first",
             "second",
             "mock: second"
           ]

    assert Enum.map(context.retained_messages, & &1.content) == ["third", "mock: third"]

    assert {:ok, autosave} =
             Tet.autosave_session(session_id, prompt_attrs("compact-req"),
               saved_at: "2025-01-01T00:00:02.000Z",
               compaction: [force: true, recent_count: 2, strategy: :autosave_summary]
             )

    assert length(autosave.messages) == 6

    kinds = Enum.map(autosave.prompt_debug["layers"], & &1["kind"])
    assert Enum.count(kinds, &(&1 == "session_message")) == 2
    assert "compaction_metadata" in kinds

    compaction_layer =
      Enum.find(autosave.prompt_debug["layers"], &(&1["kind"] == "compaction_metadata"))

    assert compaction_layer["metadata"]["strategy"] == "autosave_summary"
    assert compaction_layer["metadata"]["original_message_count"] == 6
    assert compaction_layer["metadata"]["retained_message_count"] == 2
    assert compaction_layer["metadata"]["compacted_message_count"] == 4
    assert compaction_layer["metadata"]["source_message_ids"] |> length() == 4
  end

  test "autosave rejects raw attachment payload fields and does not write a checkpoint" do
    session_id = unique_session("payload")

    assert {:ok, _result} =
             Tet.ask("payload guard",
               provider: :mock,
               session_id: session_id
             )

    assert {:error, {:invalid_prompt_attachment, 0, :content_not_allowed}} =
             Tet.autosave_session(
               session_id,
               [
                 system: "base",
                 attachments: [%{name: "secret.txt", content: "raw bytes stay out"}]
               ],
               saved_at: "2025-01-01T00:00:00.000Z"
             )

    # With SQLite, autosaves are persisted in the DB not a file.
    # Verify the rejected autosave was not written by confirming no
    # checkpoint with the session_id exists.
    assert {:ok, autosaves} = Tet.list_autosaves()
    refute Enum.any?(autosaves, &(&1.session_id == session_id))
  end

  defp prompt_attrs(request_id) do
    [
      system: "You are Tet fixture runtime.",
      metadata: %{request_id: request_id, suite: "autosave"},
      project_rules: [
        %{
          id: "rules:fixture",
          content: "Keep autosave fixtures deterministic.",
          source: "test"
        }
      ],
      attachments: [
        %{
          id: "attachment-fixture",
          name: "design-notes.md",
          media_type: "text/markdown",
          byte_size: 128,
          sha256: String.duplicate("b", 64),
          source: "fixture",
          metadata: %{label: "restore-fixture"}
        }
      ]
    ]
  end

  defp unique_session(name), do: "session-#{name}-#{System.pid()}-#{unique_integer()}"

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
  end
end
