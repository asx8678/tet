defmodule Tet.Store.SQLite.Repo.Migrations.CreateApprovals do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS approvals (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
      tool_run_id TEXT NOT NULL REFERENCES tool_runs(id) ON DELETE CASCADE,
      short_id TEXT CHECK (short_id IS NULL OR length(short_id) > 0),
      status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'rejected')),
      reason TEXT NOT NULL DEFAULT '',
      diff_artifact_id TEXT NOT NULL REFERENCES artifacts(id) ON DELETE RESTRICT,
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      resolved_at INTEGER
    )
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS approvals_one_pending_per_session
    ON approvals(session_id)
    WHERE status = 'pending'
    """

    execute """
    CREATE INDEX IF NOT EXISTS approvals_session_created_idx
    ON approvals(session_id, created_at DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS approvals_task_idx
    ON approvals(task_id)
    WHERE task_id IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS approvals_tool_run_idx
    ON approvals(tool_run_id)
    """

    execute """
    CREATE INDEX IF NOT EXISTS approvals_diff_artifact_idx
    ON approvals(diff_artifact_id)
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS approvals_session_short_id_idx
    ON approvals(session_id, short_id)
    WHERE short_id IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS approvals_session_short_id_idx"
    execute "DROP INDEX IF EXISTS approvals_diff_artifact_idx"
    execute "DROP INDEX IF EXISTS approvals_tool_run_idx"
    execute "DROP INDEX IF EXISTS approvals_task_idx"
    execute "DROP INDEX IF EXISTS approvals_session_created_idx"
    execute "DROP INDEX IF EXISTS approvals_one_pending_per_session"
    execute "DROP TABLE IF EXISTS approvals"
  end
end
