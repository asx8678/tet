defmodule Tet.AutosaveRestoreTest do
  use ExUnit.Case, async: false

  setup do
    tmp_root = unique_tmp_root("tet-autosave-test")

    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    {:ok, tmp_root: tmp_root}
  end

  test "autosaves and restores a session with attachments and prompt debug metadata", %{
    tmp_root: tmp_root
  } do
    store_path = Path.join(tmp_root, "messages.jsonl")
    autosave_path = Path.join(tmp_root, "autosaves.jsonl")
    session_id = unique_session("fixture")

    assert {:ok, ask_result} =
             Tet.ask("fixture turn",
               provider: :mock,
               store_path: store_path,
               session_id: session_id
             )

    assert ask_result.session_id == session_id

    assert {:ok, first} =
             Tet.autosave_session(session_id, prompt_attrs("req-1"),
               store_path: store_path,
               autosave_path: autosave_path,
               checkpoint_id: "checkpoint-old",
               saved_at: "2025-01-01T00:00:00.000Z",
               autosave_metadata: %{fixture: "old"}
             )

    assert {:ok, second} =
             Tet.autosave_session(session_id, prompt_attrs("req-2"),
               store_path: store_path,
               autosave_path: autosave_path,
               checkpoint_id: "checkpoint-new",
               saved_at: "2025-01-01T00:00:01.000Z",
               autosave_metadata: %{fixture: "new"}
             )

    assert {:ok, [listed_new, listed_old]} = Tet.list_autosaves(autosave_path: autosave_path)
    assert listed_new.checkpoint_id == "checkpoint-new"
    assert listed_old.checkpoint_id == "checkpoint-old"

    assert {:ok, restored} = Tet.restore_autosave(session_id, autosave_path: autosave_path)

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

  test "autosave rejects raw attachment payload fields and does not write a checkpoint", %{
    tmp_root: tmp_root
  } do
    store_path = Path.join(tmp_root, "messages.jsonl")
    autosave_path = Path.join(tmp_root, "autosaves.jsonl")
    session_id = unique_session("payload")

    assert {:ok, _result} =
             Tet.ask("payload guard",
               provider: :mock,
               store_path: store_path,
               session_id: session_id
             )

    assert {:error, {:invalid_prompt_attachment, 0, :content_not_allowed}} =
             Tet.autosave_session(
               session_id,
               [
                 system: "base",
                 attachments: [%{name: "secret.txt", content: "raw bytes stay out"}]
               ],
               store_path: store_path,
               autosave_path: autosave_path,
               saved_at: "2025-01-01T00:00:00.000Z"
             )

    refute File.exists?(autosave_path)
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

  defp unique_tmp_root(prefix) do
    suffix = "#{System.pid()}-#{System.system_time(:nanosecond)}-#{unique_integer()}"
    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
  end

  defp unique_session(name), do: "session-#{name}-#{System.pid()}-#{unique_integer()}"

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
  end
end
