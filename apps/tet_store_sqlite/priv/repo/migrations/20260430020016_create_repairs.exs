defmodule Tet.Store.SQLite.Repo.Migrations.CreateRepairs do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS repairs (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      error_log_id TEXT NOT NULL REFERENCES error_log(id) ON DELETE CASCADE,
      session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
      strategy TEXT NOT NULL CHECK (strategy IN ('retry', 'fallback', 'patch', 'human')),
      params BLOB,
      result BLOB,
      status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'succeeded', 'failed', 'skipped')),
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL,
      started_at INTEGER,
      completed_at INTEGER
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS repairs_session_status_idx
    ON repairs(session_id, status, created_at)
    WHERE session_id IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS repairs_pending_idx
    ON repairs(status, created_at ASC)
    WHERE status = 'pending'
    """

    execute """
    CREATE INDEX IF NOT EXISTS repairs_error_log_idx
    ON repairs(error_log_id)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS repairs_error_log_idx"
    execute "DROP INDEX IF EXISTS repairs_pending_idx"
    execute "DROP INDEX IF EXISTS repairs_session_status_idx"
    execute "DROP TABLE IF EXISTS repairs"
  end
end
