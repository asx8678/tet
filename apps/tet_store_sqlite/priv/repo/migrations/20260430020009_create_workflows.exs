defmodule Tet.Store.SQLite.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS workflows (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
      status TEXT NOT NULL CHECK (status IN ('running', 'paused_for_approval', 'completed', 'failed', 'cancelled')),
      claimed_by TEXT,
      claim_expires_at INTEGER,
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS workflows_session_status_idx
    ON workflows(session_id, status, updated_at DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS workflows_task_idx
    ON workflows(task_id)
    WHERE task_id IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS workflows_pending_idx
    ON workflows(status, updated_at)
    WHERE status IN ('running', 'paused_for_approval')
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS workflows_one_paused_per_session
    ON workflows(session_id)
    WHERE status = 'paused_for_approval'
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS workflows_one_paused_per_session"
    execute "DROP INDEX IF EXISTS workflows_pending_idx"
    execute "DROP INDEX IF EXISTS workflows_task_idx"
    execute "DROP INDEX IF EXISTS workflows_session_status_idx"
    execute "DROP TABLE IF EXISTS workflows"
  end
end
