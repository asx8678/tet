defmodule Tet.Store.SQLite.WorkflowStepsTest do
  use ExUnit.Case, async: false

  setup do
    tmp_root = unique_tmp_root("tet-sqlite-wf-steps-test")
    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)

    workflow_steps_path = Path.join(tmp_root, "workflow_steps.jsonl")

    opts = [
      workflow_steps_path: workflow_steps_path
    ]

    {:ok, opts: opts, tmp_root: tmp_root, workflow_steps_path: workflow_steps_path}
  end

  defp unique_tmp_root(prefix) do
    suffix = "#{System.pid()}-#{System.system_time(:nanosecond)}-#{unique_integer()}"
    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
  end

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
  end

  defp append_step(attrs, opts) do
    Tet.Store.SQLite.append_step(attrs, opts)
  end

  describe "list_steps/2 (with opts)" do
    test "returns steps for a given workflow_id", %{opts: opts} do
      assert {:ok, _s1} =
               append_step(
                 %{
                   id: "step_wf_a_1",
                   workflow_id: "wf_a",
                   session_id: "ses_test",
                   name: "research",
                   idempotency_key: "ik_001",
                   status: :pending
                 },
                 opts
               )

      assert {:ok, _s2} =
               append_step(
                 %{
                   id: "step_wf_a_2",
                   workflow_id: "wf_a",
                   session_id: "ses_test",
                   name: "analyze",
                   idempotency_key: "ik_002",
                   status: :pending
                 },
                 opts
               )

      assert {:ok, steps} = Tet.Store.SQLite.list_steps("wf_a", opts)
      step_ids = Enum.map(steps, & &1.id)
      assert "step_wf_a_1" in step_ids
      assert "step_wf_a_2" in step_ids
      assert length(steps) == 2
    end

    test "steps from other workflows are filtered out", %{opts: opts} do
      assert {:ok, _wf_a} =
               append_step(
                 %{
                   id: "step_wf_a_1",
                   workflow_id: "wf_a",
                   session_id: "ses_test",
                   name: "research",
                   idempotency_key: "ik_001",
                   status: :committed
                 },
                 opts
               )

      assert {:ok, _wf_b} =
               append_step(
                 %{
                   id: "step_wf_b_1",
                   workflow_id: "wf_b",
                   session_id: "ses_test",
                   name: "build",
                   idempotency_key: "ik_002",
                   status: :pending
                 },
                 opts
               )

      assert {:ok, steps} = Tet.Store.SQLite.list_steps("wf_a", opts)
      step_ids = Enum.map(steps, & &1.id)
      assert "step_wf_a_1" in step_ids
      refute "step_wf_b_1" in step_ids
    end

    test "returns empty list for workflow with no steps", %{opts: opts} do
      assert {:ok, steps} = Tet.Store.SQLite.list_steps("wf_nonexistent", opts)
      assert steps == []
    end

    test "preserves step ordering by created_at", %{opts: opts} do
      assert {:ok, _s1} =
               append_step(
                 %{
                   id: "step_ord_1",
                   workflow_id: "wf_order",
                   session_id: "ses_test",
                   name: "first",
                   idempotency_key: "ik_001",
                   status: :committed,
                   created_at: "2025-01-01T00:00:00Z"
                 },
                 opts
               )

      assert {:ok, _s2} =
               append_step(
                 %{
                   id: "step_ord_2",
                   workflow_id: "wf_order",
                   session_id: "ses_test",
                   name: "second",
                   idempotency_key: "ik_002",
                   status: :committed,
                   created_at: "2025-01-01T00:00:01Z"
                 },
                 opts
               )

      assert {:ok, _s3} =
               append_step(
                 %{
                   id: "step_ord_3",
                   workflow_id: "wf_order",
                   session_id: "ses_test",
                   name: "third",
                   idempotency_key: "ik_003",
                   status: :pending,
                   created_at: "2025-01-01T00:00:02Z"
                 },
                 opts
               )

      assert {:ok, steps} = Tet.Store.SQLite.list_steps("wf_order", opts)
      step_names = Enum.map(steps, & &1.step_name)
      assert step_names == ["first", "second", "third"]
    end
  end

  describe "list_steps/1 (callback, default path via env)" do
    setup %{workflow_steps_path: workflow_steps_path} do
      original_env = System.get_env("TET_WORKFLOW_STEPS_PATH")
      System.put_env("TET_WORKFLOW_STEPS_PATH", workflow_steps_path)

      on_exit(fn ->
        if original_env do
          System.put_env("TET_WORKFLOW_STEPS_PATH", original_env)
        else
          System.delete_env("TET_WORKFLOW_STEPS_PATH")
        end
      end)

      :ok
    end

    test "returns steps via callback signature using env-configured path", %{opts: opts} do
      assert {:ok, _step} =
               append_step(
                 %{
                   id: "step_cb_1",
                   workflow_id: "wf_cb",
                   session_id: "ses_cb",
                   name: "research",
                   idempotency_key: "ik_001",
                   status: :pending
                 },
                 opts
               )

      assert {:ok, _step} =
               append_step(
                 %{
                   id: "step_cb_2",
                   workflow_id: "wf_cb",
                   session_id: "ses_cb",
                   name: "build",
                   idempotency_key: "ik_002",
                   status: :committed
                 },
                 opts
               )

      # list_steps/1 reads from TET_WORKFLOW_STEPS_PATH env var
      assert {:ok, steps} = Tet.Store.SQLite.list_steps("wf_cb")
      step_ids = Enum.map(steps, & &1.id)
      assert "step_cb_1" in step_ids
      assert "step_cb_2" in step_ids
      assert length(steps) == 2
    end

    test "callback filters by workflow_id correctly", %{opts: opts} do
      assert {:ok, _wf_a} =
               append_step(
                 %{
                   id: "step_cb_a_1",
                   workflow_id: "wf_cb_filter_a",
                   session_id: "ses_cb",
                   name: "research",
                   idempotency_key: "ik_001",
                   status: :pending
                 },
                 opts
               )

      assert {:ok, _wf_b} =
               append_step(
                 %{
                   id: "step_cb_b_1",
                   workflow_id: "wf_cb_filter_b",
                   session_id: "ses_cb",
                   name: "build",
                   idempotency_key: "ik_002",
                   status: :pending
                 },
                 opts
               )

      assert {:ok, steps} = Tet.Store.SQLite.list_steps("wf_cb_filter_a")
      step_ids = Enum.map(steps, & &1.id)
      assert "step_cb_a_1" in step_ids
      refute "step_cb_b_1" in step_ids
    end
  end

  describe "consistency with get_steps/2" do
    test "list_steps and get_steps use same path resolution", %{opts: opts} do
      step_id = "step_cons_1"

      assert {:ok, _step} =
               append_step(
                 %{
                   id: step_id,
                   workflow_id: "wf_cons",
                   session_id: "ses_cons",
                   name: "research",
                   idempotency_key: "ik_001",
                   status: :pending
                 },
                 opts
               )

      # Both functions should find the persisted step
      assert {:ok, steps_by_workflow} = Tet.Store.SQLite.list_steps("wf_cons", opts)
      assert {:ok, steps_by_session} = Tet.Store.SQLite.get_steps("ses_cons", opts)

      wf_ids = Enum.map(steps_by_workflow, & &1.id)
      ses_ids = Enum.map(steps_by_session, & &1.id)

      assert step_id in wf_ids
      assert step_id in ses_ids
    end
  end
end
