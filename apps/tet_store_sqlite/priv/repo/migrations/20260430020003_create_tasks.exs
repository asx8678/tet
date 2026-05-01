defmodule Tet.Store.SQLite.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS tasks (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      short_id TEXT CHECK (short_id IS NULL OR length(short_id) > 0),
      title TEXT NOT NULL,
      kind TEXT NOT NULL DEFAULT 'agent_task',
      status TEXT NOT NULL CHECK (status IN ('active', 'complete', 'cancelled')),
      payload BLOB,
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS tasks_session_created_idx
    ON tasks(session_id, created_at)
    """

    execute """
    CREATE INDEX IF NOT EXISTS tasks_session_status_idx
    ON tasks(session_id, status)
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS tasks_session_short_id_idx
    ON tasks(session_id, short_id)
    WHERE short_id IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS tasks_session_short_id_idx"
    execute "DROP INDEX IF EXISTS tasks_session_status_idx"
    execute "DROP INDEX IF EXISTS tasks_session_created_idx"
    execute "DROP TABLE IF EXISTS tasks"
  end
end
