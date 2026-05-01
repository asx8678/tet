defmodule Tet.Store.SQLite.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      short_id TEXT NOT NULL CHECK (length(short_id) > 0),
      title TEXT,
      mode TEXT NOT NULL CHECK (mode IN ('chat', 'explore', 'execute')),
      status TEXT NOT NULL CHECK (status IN ('idle', 'running', 'waiting_approval', 'complete', 'error')),
      provider TEXT,
      model TEXT,
      active_task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL,
      started_at INTEGER,
      updated_at INTEGER NOT NULL,
      UNIQUE (workspace_id, short_id)
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS sessions_workspace_created_idx
    ON sessions(workspace_id, created_at DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS sessions_active_task_idx
    ON sessions(active_task_id)
    WHERE active_task_id IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS sessions_active_task_idx"
    execute "DROP INDEX IF EXISTS sessions_workspace_created_idx"
    execute "DROP TABLE IF EXISTS sessions"
  end
end
