defmodule Tet.CheckpointTest do
  use ExUnit.Case, async: false

  setup do
    Tet.Store.Memory.reset()
    :ok
  end

  # ── Checkpoint.create/4 ────────────────────────────────────────────────────

  describe "create/4" do
    test "creates a checkpoint with a state snapshot" do
      assert {:ok, cp} =
               Tet.Checkpoint.create(Tet.Store.Memory, "ses_001", %{foo: "bar", count: 42})

      assert String.starts_with?(cp.id, "cp_")
      assert cp.session_id == "ses_001"
      assert cp.state_snapshot == %{foo: "bar", count: 42}
      assert is_binary(cp.sha256)
      assert byte_size(cp.sha256) == 64
      assert is_binary(cp.created_at)
    end

    test "accepts optional task_id and workflow_id" do
      assert {:ok, cp} =
               Tet.Checkpoint.create(Tet.Store.Memory, "ses_002", %{},
                 task_id: "task_99",
                 workflow_id: "wf_42"
               )

      assert cp.task_id == "task_99"
      assert cp.workflow_id == "wf_42"
    end

    test "accepts custom id via options" do
      assert {:ok, cp} =
               Tet.Checkpoint.create(Tet.Store.Memory, "ses_003", %{}, id: "my_custom_id")

      assert cp.id == "my_custom_id"
    end

    test "accepts metadata via options" do
      assert {:ok, cp} =
               Tet.Checkpoint.create(Tet.Store.Memory, "ses_004", %{},
                 metadata: %{reason: "before_mutation", trigger: :tool_call}
               )

      assert cp.metadata == %{reason: "before_mutation", trigger: :tool_call}
    end

    test "produces deterministic sha256 for identical snapshots" do
      assert {:ok, cp1} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_005", %{a: 1, b: 2})
      assert {:ok, cp2} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_005", %{a: 1, b: 2})

      assert cp1.sha256 == cp2.sha256
      assert cp1.id != cp2.id
    end

    test "produces different sha256 for different snapshots" do
      assert {:ok, cp1} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_006", %{a: 1})
      assert {:ok, cp2} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_006", %{a: 2})

      refute cp1.sha256 == cp2.sha256
    end

    test "persists the checkpoint in the store" do
      assert {:ok, cp} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_007", %{x: 1})

      assert {:ok, fetched} = Tet.Store.Memory.get_checkpoint(cp.id, [])
      assert fetched.id == cp.id
      assert fetched.state_snapshot == %{x: 1}
    end
  end

  # ── Checkpoint.restore/3 ───────────────────────────────────────────────────

  describe "restore/3" do
    test "restores a state snapshot from a checkpoint" do
      snapshot = %{messages: ["hello", "world"], count: 2}
      assert {:ok, cp} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_010", snapshot)

      assert {:ok, restored} = Tet.Checkpoint.restore(Tet.Store.Memory, cp.id)
      assert restored == snapshot
    end

    test "returns error for non-existent checkpoint" do
      assert {:error, :checkpoint_not_found} =
               Tet.Checkpoint.restore(Tet.Store.Memory, "cp_nonexistent")
    end

    test "returns error for checkpoint with nil snapshot" do
      # Create a checkpoint manually with nil snapshot
      {:ok, cp} =
        Tet.Checkpoint.new(%{
          id: "cp_empty",
          session_id: "ses_011"
        })

      {:ok, _} = Tet.Store.Memory.save_checkpoint(Tet.Checkpoint.to_map(cp), [])

      assert {:error, :empty_checkpoint_snapshot} =
               Tet.Checkpoint.restore(Tet.Store.Memory, "cp_empty")
    end

    test "passes opts to store" do
      # The store ignores opts anyway, just verifying the plumbing
      assert {:ok, cp} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_012", %{a: 1})
      assert {:ok, %{a: 1}} = Tet.Checkpoint.restore(Tet.Store.Memory, cp.id, [])
    end
  end

  # ── Checkpoint.list/3 ──────────────────────────────────────────────────────

  describe "list/3" do
    test "lists all checkpoints for a session" do
      assert {:ok, cp1} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_020", %{step: 1})
      assert {:ok, cp2} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_020", %{step: 2})

      assert {:ok, checkpoints} = Tet.Checkpoint.list(Tet.Store.Memory, "ses_020")
      assert length(checkpoints) == 2
      assert Enum.any?(checkpoints, &(&1.id == cp1.id))
      assert Enum.any?(checkpoints, &(&1.id == cp2.id))
    end

    test "does not mix sessions" do
      assert {:ok, _} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_021", %{a: 1})
      assert {:ok, _} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_022", %{b: 2})

      assert {:ok, checkpoints} = Tet.Checkpoint.list(Tet.Store.Memory, "ses_021")
      assert length(checkpoints) == 1
      assert hd(checkpoints).session_id == "ses_021"
    end

    test "returns empty list when no checkpoints exist" do
      assert {:ok, []} = Tet.Checkpoint.list(Tet.Store.Memory, "ses_nonexistent")
    end
  end

  # ── Checkpoint.delete/3 ────────────────────────────────────────────────────

  describe "delete/3" do
    test "deletes a checkpoint by id" do
      assert {:ok, cp} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_030", %{x: 1})
      assert {:ok, :ok} = Tet.Checkpoint.delete(Tet.Store.Memory, cp.id)
      assert {:error, :checkpoint_not_found} = Tet.Checkpoint.restore(Tet.Store.Memory, cp.id)
    end

    test "succeeds even if checkpoint does not exist" do
      assert {:ok, :ok} = Tet.Checkpoint.delete(Tet.Store.Memory, "cp_nonexistent")
    end

    test "does not affect other checkpoints" do
      assert {:ok, cp1} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_031", %{a: 1})
      assert {:ok, cp2} = Tet.Checkpoint.create(Tet.Store.Memory, "ses_031", %{a: 2})

      assert {:ok, :ok} = Tet.Checkpoint.delete(Tet.Store.Memory, cp1.id)

      assert {:ok, [cp]} = Tet.Checkpoint.list(Tet.Store.Memory, "ses_031")
      assert cp.id == cp2.id
    end
  end

  # ── Replay.replay_workflow/4 ───────────────────────────────────────────────

  describe "Replay.replay_workflow/4" do
    setup :create_test_steps

    test "skips already committed steps" do
      step_fn = fn step, _store ->
        send(self(), {:executed, step.step_name})
        {:ok, step.step_name <> "_done"}
      end

      assert {:ok, summary} =
               Tet.Checkpoint.Replay.replay_workflow(Tet.Store.Memory, "wf_replay", step_fn)

      assert summary.total == 3
      assert summary.skipped == 1
      assert summary.replayed == 2
      assert summary.failed == 0

      # Committed step NOT executed
      refute_received {:executed, "fetch_data"}
      # Pending steps WERE executed
      assert_received {:executed, "process_data"}
      assert_received {:executed, "save_results"}
    end

    test "replays pending steps in order" do
      step_fn = fn step, _store ->
        send(self(), {:executed, step.step_name, step.id})
        {:ok, step.step_name <> "_done"}
      end

      assert {:ok, _summary} =
               Tet.Checkpoint.Replay.replay_workflow(Tet.Store.Memory, "wf_replay", step_fn)

      # Should NOT receive committed step, only pending ones in order
      refute_received {:executed, "fetch_data", _}
      assert_received {:executed, "process_data", "step_fetch_resp"}
      assert_received {:executed, "save_results", "step_save"}
      refute_received {:executed, _, _}
    end

    test "returns error when a step fails" do
      step_fn = fn
        %Tet.WorkflowStep{step_name: "process_data"}, _store ->
          {:error, :network_timeout}

        step, _store ->
          {:ok, step.step_name <> "_done"}
      end

      assert {:error, {:step_failed, "process_data", "step_fetch_resp", :network_timeout}} =
               Tet.Checkpoint.Replay.replay_workflow(Tet.Store.Memory, "wf_replay", step_fn)
    end

    test "calls on_skip callback for skipped steps" do
      assert {:ok, _summary} =
               Tet.Checkpoint.Replay.replay_workflow(
                 Tet.Store.Memory,
                 "wf_replay",
                 fn s, _ -> {:ok, s.step_name <> "_done"} end,
                 on_skip: fn step, reason ->
                   send(self(), {:skipped, step.step_name, reason})
                 end
               )

      assert_received {:skipped, "fetch_data", :already_committed}
    end

    test "handles empty workflow with no steps" do
      assert {:ok, summary} =
               Tet.Checkpoint.Replay.replay_workflow(Tet.Store.Memory, "wf_empty", fn _s, _ ->
                 {:ok, "done"}
               end)

      assert summary == %{total: 0, skipped: 0, replayed: 0, failed: 0}
    end

    test "returns error for non-existent workflow" do
      assert {:ok, summary} =
               Tet.Checkpoint.Replay.replay_workflow(Tet.Store.Memory, "wf_does_not_exist", fn _s,
                                                                                               _ ->
                 {:ok, "done"}
               end)

      assert summary.total == 0
    end

    # ── Non-deterministic step handling ──

    test "replays non-deterministic steps by default" do
      step_fn = fn step, _store ->
        send(self(), {:executed, step.step_name})
        {:ok, step.step_name <> "_done"}
      end

      assert {:ok, _summary} =
               Tet.Checkpoint.Replay.replay_workflow(Tet.Store.Memory, "wf_non_det", step_fn)

      assert_received {:executed, "random_op"}
    end

    test "fails on non-deterministic step when fail_on_non_deterministic is true" do
      assert {:error, {:non_deterministic_step, "random_op", _id}} =
               Tet.Checkpoint.Replay.replay_workflow(
                 Tet.Store.Memory,
                 "wf_non_det",
                 fn _s, _ -> {:ok, "done"} end,
                 fail_on_non_deterministic: true
               )
    end

    test "calls on_non_deterministic callback" do
      assert {:ok, _summary} =
               Tet.Checkpoint.Replay.replay_workflow(
                 Tet.Store.Memory,
                 "wf_non_det",
                 fn s, _ -> {:ok, s.step_name <> "_done"} end,
                 on_non_deterministic: fn step ->
                   send(self(), {:non_deterministic, step.step_name})
                 end
               )

      assert_received {:non_deterministic, "random_op"}
    end
  end

  # ── Replay.replay_session/4 ────────────────────────────────────────────────

  describe "Replay.replay_session/4" do
    setup :create_multi_workflow_steps

    test "replays steps across multiple workflows" do
      assert {:ok, results} =
               Tet.Checkpoint.Replay.replay_session(Tet.Store.Memory, "ses_multi", fn s, _ ->
                 {:ok, s.step_name <> "_done"}
               end)

      assert length(results) == 2

      wf_a_result = Enum.find(results, &(&1.workflow_id == "wf_multi_a"))
      wf_b_result = Enum.find(results, &(&1.workflow_id == "wf_multi_b"))

      assert wf_a_result.summary.total == 1
      assert wf_a_result.summary.skipped == 0
      assert wf_a_result.summary.replayed == 1

      assert wf_b_result.summary.total == 1
      assert wf_b_result.summary.skipped == 1
      assert wf_b_result.summary.replayed == 0
    end

    test "returns results for each workflow" do
      assert {:ok, results} =
               Tet.Checkpoint.Replay.replay_session(Tet.Store.Memory, "ses_multi", fn s, _ ->
                 {:ok, s.step_name <> "_done"}
               end)

      assert Enum.all?(results, &(&1.workflow_id != nil))
      assert Enum.all?(results, &Map.has_key?(&1, :summary))
    end
  end

  # ── Idempotency ────────────────────────────────────────────────────────────

  describe "replay idempotency" do
    setup :create_test_steps

    test "replaying the same workflow twice produces identical summary counts" do
      step_fn = fn s, _store ->
        {:ok, s.step_name <> "_done"}
      end

      assert {:ok, s1} =
               Tet.Checkpoint.Replay.replay_workflow(Tet.Store.Memory, "wf_replay", step_fn)

      assert {:ok, s2} =
               Tet.Checkpoint.Replay.replay_workflow(Tet.Store.Memory, "wf_replay", step_fn)

      # Both runs produce identical counts since store status doesn't change
      assert s1 == s2
      assert s1.replayed == 2
      assert s1.skipped == 1
      assert s1.total == 3
    end
  end

  # ── Regression: opts propagation to SQLite adapter ─────────────────────────

  describe "replay_workflow with SQLite adapter and custom opts" do
    setup :create_sqlite_steps_with_opts

    test "replay_workflow/4 forwards opts to store.list_steps/2" do
      step_fn = fn step, _store ->
        send(self(), {:executed, step.step_name})
        {:ok, step.step_name <> "_done"}
      end

      assert {:ok, summary} =
               Tet.Checkpoint.Replay.replay_workflow(
                 Tet.Store.SQLite,
                 "wf_sqlite_opts",
                 step_fn,
                 []
               )

      assert summary.total == 2
      assert summary.skipped == 1
      assert summary.replayed == 1
      assert summary.failed == 0

      refute_received {:executed, "already_done"}
      assert_received {:executed, "needs_replay"}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp create_test_steps(%{}) do
    now = DateTime.utc_now()

    steps = [
      %Tet.WorkflowStep{
        id: "step_fetch",
        workflow_id: "wf_replay",
        session_id: "ses_replay",
        step_name: "fetch_data",
        idempotency_key: "ik_fetch",
        status: :committed,
        input: %{url: "/api/data"},
        output: %{data: [1, 2, 3]},
        created_at: now
      },
      %Tet.WorkflowStep{
        id: "step_fetch_resp",
        workflow_id: "wf_replay",
        session_id: "ses_replay",
        step_name: "process_data",
        idempotency_key: "ik_process",
        status: :pending,
        input: %{data: [1, 2, 3]},
        created_at: DateTime.add(now, 1, :second)
      },
      %Tet.WorkflowStep{
        id: "step_save",
        workflow_id: "wf_replay",
        session_id: "ses_replay",
        step_name: "save_results",
        idempotency_key: "ik_save",
        status: :pending,
        input: %{results: "processed"},
        created_at: DateTime.add(now, 2, :second)
      }
    ]

    Enum.each(steps, &store_step/1)

    # Also add a workflow with a non-deterministic step
    nd_step = %Tet.WorkflowStep{
      id: "step_nd_1",
      workflow_id: "wf_non_det",
      session_id: "ses_replay",
      step_name: "random_op",
      idempotency_key: "ik_nd",
      status: :pending,
      input: %{},
      metadata: %{"non_deterministic" => true},
      created_at: DateTime.utc_now()
    }

    store_step(nd_step)

    :ok
  end

  defp create_multi_workflow_steps(%{}) do
    now = DateTime.utc_now()

    steps = [
      %Tet.WorkflowStep{
        id: "step_multi_a",
        workflow_id: "wf_multi_a",
        session_id: "ses_multi",
        step_name: "action_a",
        idempotency_key: "ik_multi_a",
        status: :pending,
        input: %{},
        created_at: now
      },
      %Tet.WorkflowStep{
        id: "step_multi_b",
        workflow_id: "wf_multi_b",
        session_id: "ses_multi",
        step_name: "action_b",
        idempotency_key: "ik_multi_b",
        status: :committed,
        input: %{},
        output: %{done: true},
        created_at: DateTime.add(now, 1, :second)
      }
    ]

    Enum.each(steps, &store_step/1)
    :ok
  end

  defp store_step(step) do
    {:ok, _} = Tet.Store.Memory.append_step(Tet.WorkflowStep.to_map(step), [])
    :ok
  end

  defp create_sqlite_steps_with_opts(%{}) do
    now = DateTime.utc_now()
    n = System.unique_integer([:positive, :monotonic])

    # Clean SQLite tables to prevent unique constraint collisions from previous runs.
    # FK-ordered: children first, then parents.
    cleanup_tables = [
      "workflow_steps",
      "workflows",
      "events",
      "messages",
      "tasks",
      "sessions",
      "workspaces"
    ]

    for table <- cleanup_tables do
      Ecto.Adapters.SQL.query!(Tet.Store.SQLite.Repo, "DELETE FROM #{table}", [])
    end

    # Create FK parent chain required by SQLite adapter
    ws_id = "ws_cp_sqlite_#{n}"
    ses_id = "ses_cp_sqlite_#{n}"
    wf_id = "wf_sqlite_opts"

    {:ok, _} =
      Tet.Store.SQLite.create_workspace(%{
        id: ws_id,
        name: "checkpoint-test",
        root_path: "/tmp/cp-test-#{ws_id}",
        tet_dir_path: "/tmp/cp-test-#{ws_id}/.tet",
        trust_state: :trusted
      })

    {:ok, _} =
      Tet.Store.SQLite.create_session(%{
        id: ses_id,
        workspace_id: ws_id,
        short_id: String.slice(ses_id, 0, 8),
        mode: :chat,
        status: :idle
      })

    {:ok, _} =
      Tet.Store.SQLite.create_workflow(%{
        id: wf_id,
        session_id: ses_id,
        status: :running
      })

    # 64-char hex idempotency keys (required by SQLite CHECK constraint)
    idem_key_1 = "cc" <> String.duplicate("a1", 31)
    idem_key_2 = "dd" <> String.duplicate("b2", 31)

    steps = [
      %Tet.WorkflowStep{
        id: "sqlite_step_1",
        workflow_id: wf_id,
        session_id: ses_id,
        step_name: "already_done",
        idempotency_key: idem_key_1,
        status: :committed,
        attempt: 1,
        input: %{},
        output: %{done: true},
        created_at: now
      },
      %Tet.WorkflowStep{
        id: "sqlite_step_2",
        workflow_id: wf_id,
        session_id: ses_id,
        step_name: "needs_replay",
        idempotency_key: idem_key_2,
        status: :started,
        attempt: 1,
        input: %{foo: "bar"},
        created_at: DateTime.add(now, 1, :second)
      }
    ]

    Enum.each(steps, fn step ->
      {:ok, _} = Tet.Store.SQLite.append_step(Tet.WorkflowStep.to_map(step), [])
    end)

    :ok
  end
end
