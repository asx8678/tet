defmodule Tet.Store.SQLite.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS events (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      seq INTEGER NOT NULL CHECK (seq > 0),
      type TEXT NOT NULL,
      payload BLOB NOT NULL DEFAULT X'7B7D',
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      inserted_at INTEGER NOT NULL
    )
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS events_session_seq
    ON events(session_id, seq)
    """

    execute """
    CREATE INDEX IF NOT EXISTS events_session_inserted_idx
    ON events(session_id, inserted_at)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS events_session_inserted_idx"
    execute "DROP INDEX IF EXISTS events_session_seq"
    execute "DROP TABLE IF EXISTS events"
  end
end
