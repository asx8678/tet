defmodule Tet.Store.SQLite.WorkflowStepsTest do
  use ExUnit.Case, async: false

  alias Tet.Store.SQLite.Repo

  # 64-char lowercase hex strings satisfying DB CHECK constraints
  @idem_key_001 "aaaa0001bbbb0002cccc0003dddd0004eeee0005ffff00060000aaaa0000bbbb"
  @idem_key_002 "aaaa0002bbbb0003cccc0004dddd0005eeee0006ffff00070000aaaa0001bbbb"
  @idem_key_003 "aaaa0003bbbb0004cccc0005dddd0006eeee0007ffff00080000aaaa0002bbbb"

  setup do
    # Clean all user tables between tests for isolation
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

    # Create FK parent chain: workspace → session → workflow
    n = unique_integer()
    ws_id = "ws_wf_steps_#{n}"
    ses_id = "ses_wf_steps_#{n}"
    wf_id = "wf_#{n}"

    {:ok, _ws} =
      Tet.Store.SQLite.create_workspace(%{
        id: ws_id,
        name: "test-workspace",
        root_path: "/tmp/test-#{ws_id}",
        tet_dir_path: "/tmp/test-#{ws_id}/.tet",
        trust_state: :trusted
      })

    {:ok, _ses} =
      Tet.Store.SQLite.create_session(%{
        id: ses_id,
        workspace_id: ws_id,
        short_id: String.slice(ses_id, 0, 8),
        mode: :chat,
        status: :idle
      })

    {:ok, _wf} =
      Tet.Store.SQLite.create_workflow(%{
        id: wf_id,
        session_id: ses_id,
        status: :running
      })

    workflow_steps_path = Path.join(System.tmp_dir!(), "tet-wf-steps-#{n}.jsonl")

    opts = [
      workflow_steps_path: workflow_steps_path,
      ws_id: ws_id,
      ses_id: ses_id,
      wf_id: wf_id
    ]

    {:ok, opts: opts, wf_id: wf_id, ses_id: ses_id}
  end

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
  end

  defp append_step(attrs, opts) do
    Tet.Store.SQLite.append_step(attrs, opts)
  end

  describe "list_steps/2 (with opts)" do
    test "returns steps for a given workflow_id", %{opts: opts, wf_id: wf_id} do
      n = unique_integer()

      assert {:ok, _s1} =
               append_step(
                 %{
                   id: "step_wf_a_1_#{n}",
                   workflow_id: wf_id,
                   session_id: opts[:ses_id],
                   name: "research",
                   idempotency_key: @idem_key_001,
                   status: :started,
                   attempt: 1
                 },
                 opts
               )

      assert {:ok, _s2} =
               append_step(
                 %{
                   id: "step_wf_a_2_#{n}",
                   workflow_id: wf_id,
                   session_id: opts[:ses_id],
                   name: "analyze",
                   idempotency_key: @idem_key_002,
                   status: :started,
                   attempt: 1
                 },
                 opts
               )

      assert {:ok, steps} = Tet.Store.SQLite.list_steps(wf_id, opts)

      step_names = Enum.map(steps, & &1.step_name)
      assert "research" in step_names
      assert "analyze" in step_names
      assert length(steps) == 2
    end

    test "steps from other workflows are filtered out", %{opts: opts, wf_id: wf_a} do
      n = unique_integer()
      # Create a second workflow for comparison
      wf_b = "wf_b_#{n}"

      {:ok, _wf} =
        Tet.Store.SQLite.create_workflow(%{
          id: wf_b,
          session_id: opts[:ses_id],
          status: :running
        })

      assert {:ok, _wf_a} =
               append_step(
                 %{
                   id: "step_wf_a_1_#{n}",
                   workflow_id: wf_a,
                   session_id: opts[:ses_id],
                   name: "research",
                   idempotency_key: @idem_key_001,
                   status: :committed,
                   attempt: 1
                 },
                 opts
               )

      assert {:ok, _wf_b} =
               append_step(
                 %{
                   id: "step_wf_b_1_#{n}",
                   workflow_id: wf_b,
                   session_id: opts[:ses_id],
                   name: "build",
                   idempotency_key: @idem_key_002,
                   status: :started,
                   attempt: 1
                 },
                 opts
               )

      assert {:ok, steps} = Tet.Store.SQLite.list_steps(wf_a, opts)
      step_ids = Enum.map(steps, & &1.id)
      assert "step_wf_a_1_#{n}" in step_ids
      refute "step_wf_b_1_#{n}" in step_ids
    end

    test "returns empty list for workflow with no steps", %{opts: opts, wf_id: wf_id} do
      assert {:ok, steps} = Tet.Store.SQLite.list_steps(wf_id, opts)
      assert steps == []
    end

    test "preserves step ordering by created_at", %{opts: opts, wf_id: wf_id} do
      assert {:ok, _s1} =
               append_step(
                 %{
                   id: "step_ord_1",
                   workflow_id: wf_id,
                   session_id: opts[:ses_id],
                   name: "first",
                   idempotency_key: @idem_key_001,
                   status: :committed,
                   attempt: 1,
                   created_at: "2025-01-01T00:00:00Z"
                 },
                 opts
               )

      assert {:ok, _s2} =
               append_step(
                 %{
                   id: "step_ord_2",
                   workflow_id: wf_id,
                   session_id: opts[:ses_id],
                   name: "second",
                   idempotency_key: @idem_key_002,
                   status: :committed,
                   attempt: 1,
                   created_at: "2025-01-01T00:00:01Z"
                 },
                 opts
               )

      assert {:ok, _s3} =
               append_step(
                 %{
                   id: "step_ord_3",
                   workflow_id: wf_id,
                   session_id: opts[:ses_id],
                   name: "third",
                   idempotency_key: @idem_key_003,
                   status: :started,
                   attempt: 1,
                   created_at: "2025-01-01T00:00:02Z"
                 },
                 opts
               )

      assert {:ok, steps} = Tet.Store.SQLite.list_steps(wf_id, opts)
      step_names = Enum.map(steps, & &1.step_name)
      assert step_names == ["first", "second", "third"]
    end
  end

  describe "list_steps/1 (callback, default path via env)" do
    setup %{opts: opts} do
      original_env = System.get_env("TET_WORKFLOW_STEPS_PATH")
      System.put_env("TET_WORKFLOW_STEPS_PATH", opts[:workflow_steps_path])

      on_exit(fn ->
        if original_env do
          System.put_env("TET_WORKFLOW_STEPS_PATH", original_env)
        else
          System.delete_env("TET_WORKFLOW_STEPS_PATH")
        end
      end)

      :ok
    end

    test "returns steps via callback signature using env-configured path", %{
      opts: opts,
      wf_id: wf_id
    } do
      n = unique_integer()

      assert {:ok, _step} =
               append_step(
                 %{
                   id: "step_cb_1_#{n}",
                   workflow_id: wf_id,
                   session_id: opts[:ses_id],
                   name: "research",
                   idempotency_key: @idem_key_001,
                   status: :started,
                   attempt: 1
                 },
                 opts
               )

      assert {:ok, _step} =
               append_step(
                 %{
                   id: "step_cb_2_#{n}",
                   workflow_id: wf_id,
                   session_id: opts[:ses_id],
                   name: "build",
                   idempotency_key: @idem_key_002,
                   status: :committed,
                   attempt: 1
                 },
                 opts
               )

      # list_steps/1 reads from TET_WORKFLOW_STEPS_PATH env var
      assert {:ok, steps} = Tet.Store.SQLite.list_steps(wf_id)
      step_names = Enum.map(steps, & &1.step_name)
      assert "research" in step_names
      assert "build" in step_names
      assert length(steps) == 2
    end

    test "callback filters by workflow_id correctly", %{opts: opts, wf_id: wf_a} do
      n = unique_integer()
      # Create a second workflow
      wf_b = "wf_cb_filter_b_#{n}"

      {:ok, _wf} =
        Tet.Store.SQLite.create_workflow(%{
          id: wf_b,
          session_id: opts[:ses_id],
          status: :running
        })

      assert {:ok, _wf_a} =
               append_step(
                 %{
                   id: "step_cb_a_1_#{n}",
                   workflow_id: wf_a,
                   session_id: opts[:ses_id],
                   name: "research",
                   idempotency_key: @idem_key_001,
                   status: :started,
                   attempt: 1
                 },
                 opts
               )

      assert {:ok, _wf_b} =
               append_step(
                 %{
                   id: "step_cb_b_1_#{n}",
                   workflow_id: wf_b,
                   session_id: opts[:ses_id],
                   name: "build",
                   idempotency_key: @idem_key_002,
                   status: :started,
                   attempt: 1
                 },
                 opts
               )

      assert {:ok, steps} = Tet.Store.SQLite.list_steps(wf_a)
      step_ids = Enum.map(steps, & &1.id)
      assert "step_cb_a_1_#{n}" in step_ids
      refute "step_cb_b_1_#{n}" in step_ids
    end
  end

  describe "consistency with get_steps/2" do
    test "list_steps and get_steps use same path resolution", %{
      opts: opts,
      wf_id: wf_id,
      ses_id: ses_id
    } do
      step_id = "step_cons_1"

      assert {:ok, _step} =
               append_step(
                 %{
                   id: step_id,
                   workflow_id: wf_id,
                   session_id: ses_id,
                   name: "research",
                   idempotency_key: @idem_key_001,
                   status: :started,
                   attempt: 1
                 },
                 opts
               )

      # Both functions should find the persisted step
      assert {:ok, steps_by_workflow} = Tet.Store.SQLite.list_steps(wf_id, opts)
      assert {:ok, steps_by_session} = Tet.Store.SQLite.get_steps(ses_id, opts)

      wf_ids = Enum.map(steps_by_workflow, & &1.id)
      ses_ids = Enum.map(steps_by_session, & &1.id)

      assert step_id in wf_ids
      assert step_id in ses_ids
    end
  end
end
