defmodule Tet.Store.SQLite.Repo.Migrations.CreateLegacyJsonlImports do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS legacy_jsonl_imports (
      source_kind TEXT NOT NULL CHECK (source_kind IN ('messages', 'events', 'autosaves', 'prompt_history')),
      source_path TEXT NOT NULL,
      source_size INTEGER NOT NULL CHECK (source_size >= 0),
      source_mtime INTEGER NOT NULL,
      sha256 TEXT NOT NULL CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
      row_count INTEGER NOT NULL CHECK (row_count >= 0),
      imported_at INTEGER NOT NULL,
      PRIMARY KEY (source_kind, source_path)
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS legacy_jsonl_imports_sha256_idx
    ON legacy_jsonl_imports(sha256)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS legacy_jsonl_imports_sha256_idx"
    execute "DROP TABLE IF EXISTS legacy_jsonl_imports"
  end
end
