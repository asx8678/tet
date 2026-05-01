defmodule Tet.Store.MemoryContractTest do
  use ExUnit.Case, async: false

  @adapter Tet.Store.Memory

  setup _context do
    # Ensure any stale agent from a previous test is stopped
    Tet.Store.Memory.stop()

    {:ok, _pid} = Tet.Store.Memory.start_link(name: Tet.Store.Memory)
    Tet.Store.Memory.reset()

    {:ok, opts: []}
  end

  # -- Event Log --

  describe "append_event/2 and get_event/2" do
    test "appends and retrieves an event by id", %{opts: opts} do
      attrs = %{
        id: "evt_001",
        type: :"session.created",
        session_id: "ses_test",
        payload: %{message: "hello"},
        metadata: %{},
        created_at: "2025-01-01T00:00:00Z"
      }

      assert {:ok, event} = @adapter.append_event(attrs, opts)
      assert event.id == "evt_001"
      assert event.type == :"session.created"
      assert event.session_id == "ses_test"

      assert {:ok, fetched} = @adapter.get_event("evt_001", opts)
      assert fetched.id == "evt_001"
    end

    test "returns error for non-existent event", %{opts: opts} do
      assert {:error, :event_not_found} = @adapter.get_event("missing_evt", opts)
    end
  end

  describe "list_events/2" do
    test "lists events for a session", %{opts: opts} do
      _ =
        @adapter.append_event(
          %{
            id: "evt_a",
            type: :"session.created",
            session_id: "ses_list",
            payload: %{},
            metadata: %{}
          },
          opts
        )

      _ =
        @adapter.append_event(
          %{
            id: "evt_b",
            type: :"provider.started",
            session_id: "ses_list",
            payload: %{},
            metadata: %{}
          },
          opts
        )

      _ =
        @adapter.append_event(
          %{
            id: "evt_c",
            type: :"session.created",
            session_id: "ses_other",
            payload: %{},
            metadata: %{}
          },
          opts
        )

      assert {:ok, events} = @adapter.list_events("ses_list", opts)
      ids = Enum.map(events, & &1.id)
      assert "evt_a" in ids
      assert "evt_b" in ids
      refute "evt_c" in ids
    end
  end

  # -- Artifacts --

  describe "create_artifact/1 and list_artifacts/2" do
    test "creates and lists artifacts by session", %{opts: opts} do
      attrs = %{
        command: ["echo", "hello"],
        risk: :low,
        exit_code: 0,
        stdout: "hello",
        stderr: "",
        cwd: "/tmp",
        duration_ms: 100,
        tool_call_id: "tc_artifact_1",
        task_id: "task_artifact_session"
      }

      assert {:ok, artifact} = @adapter.create_artifact(attrs)
      assert artifact.tool_call_id == "tc_artifact_1"

      assert {:ok, artifacts} = @adapter.list_artifacts("task_artifact_session", opts)
      assert length(artifacts) >= 1
    end
  end

  # -- Checkpoints --

  describe "save_checkpoint/2, get_checkpoint/2, list_checkpoints/2, delete_checkpoint/2" do
    test "full checkpoint lifecycle", %{opts: opts} do
      attrs = %{
        id: "cp_001",
        session_id: "ses_cp",
        sha256: "abc123",
        created_at: "2025-01-01T00:00:00Z"
      }

      assert {:ok, checkpoint} = @adapter.save_checkpoint(attrs, opts)
      assert checkpoint.id == "cp_001"
      assert checkpoint.session_id == "ses_cp"

      assert {:ok, fetched} = @adapter.get_checkpoint("cp_001", opts)
      assert fetched.id == "cp_001"

      assert {:ok, checkpoints} = @adapter.list_checkpoints("ses_cp", opts)
      assert length(checkpoints) >= 1

      assert {:ok, :ok} = @adapter.delete_checkpoint("cp_001", opts)
      assert {:error, :checkpoint_not_found} = @adapter.get_checkpoint("cp_001", opts)
    end

    test "returns error for non-existent checkpoint", %{opts: opts} do
      assert {:error, :checkpoint_not_found} = @adapter.get_checkpoint("missing_cp", opts)
    end
  end

  # -- Workflow Steps --

  describe "append_step/2 and get_steps/2" do
    test "appends and retrieves steps by session", %{opts: opts} do
      attrs = %{
        id: "step_001",
        workflow_id: "wf_001",
        session_id: "ses_steps",
        name: "research",
        idempotency_key: "ik_001",
        status: :pending
      }

      assert {:ok, step} = @adapter.append_step(attrs, opts)
      assert step.id == "step_001"
      assert step.workflow_id == "wf_001"

      assert {:ok, steps} = @adapter.get_steps("ses_steps", opts)
      step_ids = Enum.map(steps, & &1.id)
      assert "step_001" in step_ids
    end
  end

  # -- Error Log --

  describe "log_error/2, list_errors/2, get_error/2, resolve_error/2" do
    test "full error lifecycle", %{opts: opts} do
      attrs = %{
        id: "err_001",
        session_id: "ses_errors",
        kind: :provider_error,
        message: "API rate limit exceeded",
        context: %{status: 429}
      }

      assert {:ok, error_entry} = @adapter.log_error(attrs, opts)
      assert error_entry.id == "err_001"
      assert error_entry.status == :open

      assert {:ok, fetched} = @adapter.get_error("err_001", opts)
      assert fetched.id == "err_001"

      assert {:ok, errors} = @adapter.list_errors("ses_errors", opts)
      assert length(errors) >= 1

      assert {:ok, resolved} = @adapter.resolve_error("err_001", opts)
      assert resolved.status == :resolved
      assert resolved.resolved_at != nil

      # Re-fetch to confirm persistence
      assert {:ok, confirmed} = @adapter.get_error("err_001", opts)
      assert confirmed.status == :resolved
    end

    test "returns error for non-existent error", %{opts: opts} do
      assert {:error, :error_not_found} = @adapter.get_error("missing_err", opts)
    end

    test "returns error when resolving non-existent error", %{opts: opts} do
      assert {:error, :error_not_found} = @adapter.resolve_error("missing_err", opts)
    end
  end

  # -- Repair Queue --

  describe "enqueue_repair/2, dequeue_repair/1, update_repair/3, list_repairs/1" do
    test "full repair lifecycle", %{opts: opts} do
      attrs = %{
        id: "rep_001",
        error_id: "err_001",
        session_id: "ses_repairs",
        strategy: :retry,
        description: "Retry after rate limit"
      }

      assert {:ok, repair} = @adapter.enqueue_repair(attrs, opts)
      assert repair.id == "rep_001"
      assert repair.status == :pending

      # Dequeue picks up the pending repair
      assert {:ok, dequeued} = @adapter.dequeue_repair(opts)
      assert dequeued.id == "rep_001"
      assert dequeued.status == :in_progress

      # Dequeue again returns nil (no more pending)
      assert {:ok, nil} = @adapter.dequeue_repair(opts)

      # Update the repair to completed
      assert {:ok, completed} =
               @adapter.update_repair(
                 "rep_001",
                 %{status: :completed, result: %{success: true}},
                 opts
               )

      assert completed.status == :completed

      # List repairs
      assert {:ok, repairs} = @adapter.list_repairs(opts)
      assert length(repairs) >= 1

      # List by session
      assert {:ok, session_repairs} = @adapter.list_repairs(session_id: "ses_repairs")
      assert length(session_repairs) >= 1

      # List by status
      assert {:ok, completed_repairs} = @adapter.list_repairs(status: :completed)
      assert length(completed_repairs) >= 1
    end

    test "returns error for non-existent repair update", %{opts: opts} do
      assert {:error, :repair_not_found} =
               @adapter.update_repair("missing_rep", %{status: :completed}, opts)
    end
  end
end
