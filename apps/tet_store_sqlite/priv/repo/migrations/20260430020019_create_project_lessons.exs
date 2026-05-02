defmodule Tet.Store.SQLite.Repo.Migrations.CreateProjectLessons do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS project_lessons (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      title TEXT NOT NULL CHECK (length(title) > 0),
      description TEXT,
      category TEXT CHECK (category IS NULL OR category IN ('convention', 'repair_strategy', 'error_pattern', 'verification', 'performance', 'security')),
      source_finding_id TEXT NOT NULL,
      session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
      evidence_refs BLOB,
      promoted_at INTEGER,
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS project_lessons_category_idx
    ON project_lessons(category, created_at DESC)
    WHERE category IS NOT NULL
    """

    execute """
    CREATE INDEX IF NOT EXISTS project_lessons_session_idx
    ON project_lessons(session_id)
    WHERE session_id IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS project_lessons_session_idx"
    execute "DROP INDEX IF EXISTS project_lessons_category_idx"
    execute "DROP TABLE IF EXISTS project_lessons"
  end
end
