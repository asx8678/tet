defmodule Tet.Store.SQLitePromptHistoryTest do
  use ExUnit.Case, async: false

  setup do
    tmp_root = unique_tmp_root("tet-prompt-history-test")

    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    {:ok, tmp_root: tmp_root}
  end

  test "prompt history saves, lists, and fetches JSONL records without touching other stores", %{
    tmp_root: tmp_root
  } do
    store_path = Path.join(tmp_root, "messages.jsonl")
    prompt_history_path = Path.join(tmp_root, "prompt_history.jsonl")
    autosave_path = Path.join(tmp_root, "autosaves.jsonl")
    events_path = Path.join(tmp_root, "events.jsonl")
    opts = [path: store_path, prompt_history_path: prompt_history_path]

    assert {:ok, old_entry} = history_entry("prompt-history-old", "2025-01-01T00:00:00.000Z")
    assert {:ok, new_entry} = history_entry("prompt-history-new", "2025-01-01T00:00:01.000Z")

    assert {:ok, ^old_entry} = Tet.Store.SQLite.save_prompt_history(old_entry, opts)
    assert {:ok, ^new_entry} = Tet.Store.SQLite.save_prompt_history(new_entry, opts)

    assert File.exists?(prompt_history_path)
    refute File.exists?(store_path)
    refute File.exists?(autosave_path)
    refute File.exists?(events_path)

    assert {:ok, [listed_new, listed_old]} = Tet.Store.SQLite.list_prompt_history(opts)
    assert listed_new == new_entry
    assert listed_old == old_entry

    assert {:ok, fetched} = Tet.Store.SQLite.fetch_prompt_history("prompt-history-old", opts)
    assert fetched == old_entry

    assert {:error, :prompt_history_not_found} =
             Tet.Store.SQLite.fetch_prompt_history("missing", opts)
  end

  defp history_entry(id, created_at) do
    with {:ok, refinement} <-
           Tet.PromptLab.refine("Implement CLI sessions list",
             preset: "coding",
             refinement_id: "refinement-#{id}"
           ),
         {:ok, request} <-
           Tet.PromptLab.Request.new(%{
             prompt: "Implement CLI sessions list",
             preset_id: "coding",
             metadata: %{fixture: id}
           }) do
      Tet.PromptLab.HistoryEntry.new(%{
        id: id,
        created_at: created_at,
        request: request,
        result: refinement,
        metadata: %{suite: "prompt-history"}
      })
    end
  end

  defp unique_tmp_root(prefix) do
    suffix = "#{System.pid()}-#{System.system_time(:nanosecond)}-#{unique_integer()}"
    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
  end

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
  end
end
