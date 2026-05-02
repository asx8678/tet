defmodule Tet.Store.SQLite.Repo.Migrations.CreateFindings do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS findings (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
      title TEXT NOT NULL CHECK (length(title) > 0),
      description TEXT,
      source TEXT NOT NULL CHECK (source IN ('event', 'tool_run', 'failure', 'review', 'verifier', 'repair', 'manual')),
      severity TEXT NOT NULL DEFAULT 'info' CHECK (severity IN ('info', 'warning', 'critical')),
      evidence_refs BLOB,
      promoted_to BLOB,
      promoted_at INTEGER,
      status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'promoted', 'dismissed')),
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS findings_session_created_idx
    ON findings(session_id, created_at DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS findings_status_idx
    ON findings(status, created_at DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS findings_status_idx"
    execute "DROP INDEX IF EXISTS findings_session_created_idx"
    execute "DROP TABLE IF EXISTS findings"
  end
end
