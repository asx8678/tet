defmodule Tet.Store.SQLite.Repo.Migrations.CreateErrorLog do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS error_log (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
      kind TEXT NOT NULL CHECK (length(kind) > 0),
      message TEXT NOT NULL,
      stacktrace TEXT,
      context BLOB,
      status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'dismissed')),
      resolved_at INTEGER,
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS error_log_session_created_idx
    ON error_log(session_id, created_at DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS error_log_status_idx
    ON error_log(status, created_at DESC)
    WHERE status = 'open'
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS error_log_status_idx"
    execute "DROP INDEX IF EXISTS error_log_session_created_idx"
    execute "DROP TABLE IF EXISTS error_log"
  end
end
