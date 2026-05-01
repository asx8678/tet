defmodule Tet.Store.SQLite.Repo.Migrations.CreateAutosaves do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS autosaves (
      checkpoint_id TEXT PRIMARY KEY CHECK (length(checkpoint_id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      saved_at INTEGER NOT NULL,
      messages BLOB NOT NULL DEFAULT X'5B5D',
      attachments BLOB NOT NULL DEFAULT X'5B5D',
      prompt_metadata BLOB NOT NULL DEFAULT X'7B7D',
      prompt_debug BLOB NOT NULL DEFAULT X'7B7D',
      prompt_debug_text TEXT NOT NULL DEFAULT '',
      metadata BLOB NOT NULL DEFAULT X'7B7D'
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS autosaves_session_saved_idx
    ON autosaves(session_id, saved_at DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS autosaves_session_saved_idx"
    execute "DROP TABLE IF EXISTS autosaves"
  end
end
