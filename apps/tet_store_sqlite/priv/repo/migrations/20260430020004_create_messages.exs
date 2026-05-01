defmodule Tet.Store.SQLite.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      role TEXT NOT NULL CHECK (role IN ('system', 'user', 'assistant', 'tool')),
      content_kind TEXT NOT NULL DEFAULT 'text',
      content BLOB NOT NULL,
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      seq INTEGER NOT NULL CHECK (seq > 0),
      created_at INTEGER NOT NULL,
      UNIQUE (session_id, seq)
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS messages_session_created_idx
    ON messages(session_id, created_at)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS messages_session_created_idx"
    execute "DROP TABLE IF EXISTS messages"
  end
end
