defmodule Tet.Store.SQLite.Repo.Migrations.CreatePersistentMemories do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS persistent_memories (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
      title TEXT NOT NULL CHECK (length(title) > 0),
      description TEXT,
      source_finding_id TEXT NOT NULL,
      severity TEXT CHECK (severity IS NULL OR severity IN ('info', 'warning', 'critical')),
      evidence_refs BLOB,
      promoted_at INTEGER,
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS persistent_memories_session_created_idx
    ON persistent_memories(session_id, created_at DESC)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS persistent_memories_session_created_idx"
    execute "DROP TABLE IF EXISTS persistent_memories"
  end
end
