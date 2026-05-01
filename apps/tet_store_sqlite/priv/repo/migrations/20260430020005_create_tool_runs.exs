defmodule Tet.Store.SQLite.Repo.Migrations.CreateToolRuns do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS tool_runs (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
      tool_name TEXT NOT NULL,
      read_or_write TEXT NOT NULL CHECK (read_or_write IN ('read', 'write')),
      args BLOB NOT NULL DEFAULT X'7B7D',
      result BLOB,
      status TEXT NOT NULL CHECK (status IN ('proposed', 'blocked', 'waiting_approval', 'running', 'success', 'error')),
      block_reason TEXT,
      changed_files BLOB NOT NULL DEFAULT X'5B5D',
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      started_at INTEGER,
      finished_at INTEGER
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS tool_runs_session_started_idx
    ON tool_runs(session_id, started_at)
    """

    execute """
    CREATE INDEX IF NOT EXISTS tool_runs_task_idx
    ON tool_runs(task_id)
    WHERE task_id IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS tool_runs_session_status_idx
    ON tool_runs(session_id, status)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS tool_runs_session_status_idx"
    execute "DROP INDEX IF EXISTS tool_runs_task_idx"
    execute "DROP INDEX IF EXISTS tool_runs_session_started_idx"
    execute "DROP TABLE IF EXISTS tool_runs"
  end
end
