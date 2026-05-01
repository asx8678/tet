defmodule Tet.Store.SQLite.Repo.Migrations.CreatePromptHistoryEntries do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS prompt_history_entries (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      version TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      request BLOB NOT NULL,
      result BLOB NOT NULL,
      metadata BLOB NOT NULL DEFAULT X'7B7D'
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS prompt_history_created_idx
    ON prompt_history_entries(created_at DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS prompt_history_created_idx"
    execute "DROP TABLE IF EXISTS prompt_history_entries"
  end
end
