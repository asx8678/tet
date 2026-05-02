defmodule Tet.Store.SQLite.Repo.Migrations.CreateCheckpoints do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS checkpoints (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
      workflow_id TEXT REFERENCES workflows(id) ON DELETE SET NULL,
      sha256 TEXT CHECK (sha256 IS NULL OR (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*')),
      state_snapshot BLOB,
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS checkpoints_session_created_idx
    ON checkpoints(session_id, created_at DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS checkpoints_workflow_idx
    ON checkpoints(workflow_id)
    WHERE workflow_id IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS checkpoints_workflow_idx"
    execute "DROP INDEX IF EXISTS checkpoints_session_created_idx"
    execute "DROP TABLE IF EXISTS checkpoints"
  end
end
