defmodule Tet.Store.SQLiteContractTest do
  use ExUnit.Case, async: false

  alias Tet.Store.SQLite.Repo

  setup do
    # Clean all user tables between tests for isolation
    # Order matters due to foreign keys — children first, then parents
    tables = [
      "legacy_jsonl_imports",
      "project_lessons",
      "persistent_memories",
      "findings",
      "repairs",
      "error_log",
      "checkpoints",
      "workflow_steps",
      "workflows",
      "events",
      "approvals",
      "artifacts",
      "tool_runs",
      "messages",
      "autosaves",
      "prompt_history_entries",
      "tasks",
      "sessions",
      "workspaces"
    ]

    for table <- tables do
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table}", [])
    end

    {:ok, opts: []}
  end

  use StoreContractCase, adapter: Tet.Store.SQLite
end
