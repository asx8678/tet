defmodule Tet.Store.SQLite.Repo.Migrations.CreateWorkflowSteps do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS workflow_steps (
      id TEXT PRIMARY KEY CHECK (length(id) > 0),
      workflow_id TEXT NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
      step_name TEXT NOT NULL CHECK (
        length(step_name) > 0
        AND step_name NOT GLOB '*[^a-z0-9_:]*'
        AND substr(step_name, 1, 1) GLOB '[a-z_]'
        AND substr(step_name, -1, 1) <> ':'
        AND instr(step_name, '::') = 0
        AND (
          (instr(step_name, ':') = 0 AND step_name NOT GLOB '*[0-9]*')
          OR
          (instr(step_name, ':') > 0 AND substr(step_name, 1, instr(step_name, ':') - 1) NOT GLOB '*[0-9]*')
        )
      ),
      idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) = 64 AND idempotency_key NOT GLOB '*[^0-9a-f]*'),
      input BLOB NOT NULL DEFAULT X'7B7D',
      output BLOB,
      error BLOB,
      status TEXT NOT NULL CHECK (status IN ('started', 'committed', 'failed', 'cancelled')),
      attempt INTEGER NOT NULL DEFAULT 1 CHECK (attempt >= 1),
      metadata BLOB NOT NULL DEFAULT X'7B7D',
      started_at INTEGER NOT NULL,
      committed_at INTEGER,
      failed_at INTEGER,
      cancelled_at INTEGER,
      UNIQUE (workflow_id, idempotency_key)
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS workflow_steps_workflow_started_idx
    ON workflow_steps(workflow_id, started_at)
    """

    execute """
    CREATE INDEX IF NOT EXISTS workflow_steps_workflow_status_idx
    ON workflow_steps(workflow_id, status, started_at)
    """

    execute """
    CREATE INDEX IF NOT EXISTS workflow_steps_step_name_idx
    ON workflow_steps(workflow_id, step_name, attempt)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS workflow_steps_step_name_idx"
    execute "DROP INDEX IF EXISTS workflow_steps_workflow_status_idx"
    execute "DROP INDEX IF EXISTS workflow_steps_workflow_started_idx"
    execute "DROP TABLE IF EXISTS workflow_steps"
  end
end
