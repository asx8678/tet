defmodule Tet.Store.SQLitePromptHistoryTest do
  use ExUnit.Case, async: false

  setup do
    # Clean prompt_history_entries table for isolation
    Ecto.Adapters.SQL.query!(
      Tet.Store.SQLite.Repo,
      "DELETE FROM prompt_history_entries",
      []
    )

    :ok
  end

  test "prompt history saves, lists, and fetches records via Repo", _context do
    assert {:ok, old_entry} = history_entry("prompt-history-old", "2025-01-01T00:00:00Z")
    assert {:ok, new_entry} = history_entry("prompt-history-new", "2025-01-01T00:00:01Z")

    # Save both entries — exact struct match after DB round-trip is not
    # guaranteed (timestamp normalisation, atom→string keys in metadata).
    # Assert on identity and key fields instead.
    assert {:ok, saved_old} = Tet.Store.SQLite.save_prompt_history(old_entry, [])
    assert saved_old.id == old_entry.id

    assert {:ok, saved_new} = Tet.Store.SQLite.save_prompt_history(new_entry, [])
    assert saved_new.id == new_entry.id

    # List returns entries in reverse chronological order
    assert {:ok, [listed_new, listed_old]} = Tet.Store.SQLite.list_prompt_history([])
    assert listed_new.id == new_entry.id
    assert listed_old.id == old_entry.id

    # Fetch by ID
    assert {:ok, fetched} = Tet.Store.SQLite.fetch_prompt_history("prompt-history-old", [])
    assert fetched.id == old_entry.id

    assert {:error, :prompt_history_not_found} =
             Tet.Store.SQLite.fetch_prompt_history("missing", [])
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
end
