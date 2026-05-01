defmodule Tet.Store.SQLiteContractTest do
  use ExUnit.Case, async: false

  setup do
    tmp_root = unique_tmp_root("tet-sqlite-contract-test")
    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    opts = [
      path: Path.join(tmp_root, "messages.jsonl"),
      events_path: Path.join(tmp_root, "events.jsonl"),
      artifacts_path: Path.join(tmp_root, "artifacts.jsonl"),
      checkpoints_path: Path.join(tmp_root, "checkpoints.jsonl"),
      workflow_steps_path: Path.join(tmp_root, "workflow_steps.jsonl"),
      error_log_path: Path.join(tmp_root, "error_log.jsonl"),
      repairs_path: Path.join(tmp_root, "repairs.jsonl"),
      autosave_path: Path.join(tmp_root, "autosaves.jsonl"),
      prompt_history_path: Path.join(tmp_root, "prompt_history.jsonl")
    ]

    {:ok, opts: opts}
  end

  defp unique_tmp_root(prefix) do
    suffix = "#{System.pid()}-#{System.system_time(:nanosecond)}-#{unique_integer()}"
    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
  end

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
  end

  use StoreContractCase, adapter: Tet.Store.SQLite
end
