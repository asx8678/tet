defmodule Tet.Store.SQLite.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS workspaces (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      name TEXT NOT NULL,
      root_path TEXT NOT NULL UNIQUE,
      tet_dir_path TEXT NOT NULL,
      trust_state TEXT NOT NULL CHECK (trust_state IN ('untrusted', 'trusted')),
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS workspaces"
  end
end
