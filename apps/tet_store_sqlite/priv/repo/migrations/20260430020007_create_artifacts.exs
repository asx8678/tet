defmodule Tet.Store.SQLite.Repo.Migrations.CreateArtifacts do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS artifacts (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
      short_id TEXT CHECK (short_id IS NULL OR length(short_id) > 0),
      kind TEXT NOT NULL CHECK (kind IN ('diff', 'stdout', 'stderr', 'file_snapshot', 'prompt_debug', 'provider_payload')),
      sha256 TEXT NOT NULL CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
      size_bytes INTEGER NOT NULL CHECK (size_bytes >= 0),
      inline_blob BLOB,
      path TEXT,
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL,
      CHECK ((inline_blob IS NULL) <> (path IS NULL))
    )
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS artifacts_workspace_sha256_idx
    ON artifacts(workspace_id, sha256)
    """

    execute """
    CREATE INDEX IF NOT EXISTS artifacts_workspace_kind_created_idx
    ON artifacts(workspace_id, kind, created_at DESC)
    """

    execute """
    CREATE INDEX IF NOT EXISTS artifacts_session_created_idx
    ON artifacts(session_id, created_at DESC)
    WHERE session_id IS NOT NULL
    """

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS artifacts_workspace_short_id_idx
    ON artifacts(workspace_id, short_id)
    WHERE short_id IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS artifacts_workspace_short_id_idx"
    execute "DROP INDEX IF EXISTS artifacts_session_created_idx"
    execute "DROP INDEX IF EXISTS artifacts_workspace_kind_created_idx"
    execute "DROP INDEX IF EXISTS artifacts_workspace_sha256_idx"
    execute "DROP TABLE IF EXISTS artifacts"
  end
end
