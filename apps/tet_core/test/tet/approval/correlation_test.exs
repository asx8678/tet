defmodule Tet.Approval.CorrelationTest do
  @moduledoc """
  BD-0027: Cross-struct correlation and approval event integration tests.

  Verifies that every mutation has a complete approval/artifact/audit story —
  all four structs (Approval, DiffArtifact, Snapshot, BlockedAction) are
  linked via shared correlation IDs, and approval lifecycle events are
  emitted correctly.
  """

  use ExUnit.Case, async: true

  alias Tet.Approval.{Approval, BlockedAction, DiffArtifact, Snapshot}
  alias Tet.Event

  @tool_call_id "call_mutation_001"
  @session_id "ses_correlation"
  @task_id "task_correlation"

  describe "complete mutation audit trail — approved path" do
    test "approval + snapshots + diff artifact are linked by correlation IDs" do
      # 1. Approval is created (pending)
      {:ok, approval} =
        Approval.new(%{
          id: "appr_m1",
          tool_call_id: @tool_call_id,
          status: :pending,
          session_id: @session_id,
          task_id: @task_id
        })

      assert approval.status == :pending
      assert approval.tool_call_id == @tool_call_id

      # 2. Before-snapshot is taken
      before_content = "defmodule Old do end"

      {:ok, before_snap} =
        Snapshot.from_content(%{
          id: "snap_before_m1",
          file_path: "/lib/old.ex",
          action: :taken_before,
          content: before_content,
          tool_call_id: @tool_call_id,
          session_id: @session_id,
          task_id: @task_id
        })

      assert Snapshot.before?(before_snap)
      assert before_snap.tool_call_id == @tool_call_id
      assert before_snap.session_id == @session_id

      # 3. After-snapshot is taken
      after_content = "defmodule New do end"

      {:ok, after_snap} =
        Snapshot.from_content(%{
          id: "snap_after_m1",
          file_path: "/lib/old.ex",
          action: :taken_after,
          content: after_content,
          tool_call_id: @tool_call_id,
          session_id: @session_id,
          task_id: @task_id
        })

      assert Snapshot.after?(after_snap)

      # 4. Diff artifact links both snapshots
      {:ok, diff} =
        DiffArtifact.from_snapshots(before_snap, after_snap, %{
          id: "diff_m1",
          patch_text: "@@ -1 +1 @@\n-old\n+new"
        })

      assert diff.tool_call_id == @tool_call_id
      assert diff.session_id == @session_id
      assert diff.snapshot_before_id == "snap_before_m1"
      assert diff.snapshot_after_id == "snap_after_m1"
      assert diff.content_hash_before == before_snap.content_hash
      assert diff.content_hash_after == after_snap.content_hash

      # 5. Approval is approved
      {:ok, approved} = Approval.approve(approval, "adam", "Safe change")
      assert approved.status == :approved
      assert approved.approver == "adam"
      refute is_nil(approved.approved_at)

      # All records share the same correlation IDs
      for record <- [approved, before_snap, after_snap, diff] do
        assert record.tool_call_id == @tool_call_id || record.tool_call_id == nil ||
                 record.tool_call_id == @tool_call_id

        # Session and task correlation is present where applicable
      end

      assert approved.tool_call_id == @tool_call_id
      assert before_snap.tool_call_id == @tool_call_id
      assert diff.tool_call_id == @tool_call_id
    end
  end

  describe "complete mutation audit trail — blocked path" do
    test "blocked action record captures gate decision with correlation" do
      {:ok, blocked} =
        BlockedAction.new(%{
          id: "blk_m1",
          tool_name: "write-file",
          reason: :plan_mode_blocks_mutation,
          tool_call_id: @tool_call_id,
          args_summary: %{file_path: "/lib/old.ex"},
          session_id: @session_id,
          task_id: @task_id
        })

      assert blocked.reason == :plan_mode_blocks_mutation
      assert blocked.tool_call_id == @tool_call_id
      assert blocked.session_id == @session_id
      assert blocked.task_id == @task_id

      # Blocked action can be built from gate decision directly
      {:ok, from_gate} =
        BlockedAction.from_gate_decision(
          %{
            id: "blk_m1_gate",
            tool_name: "shell",
            tool_call_id: "call_gate_1",
            session_id: @session_id
          },
          {:block, :no_active_task}
        )

      assert from_gate.reason == :no_active_task
      assert from_gate.session_id == @session_id
    end
  end

  describe "approval lifecycle events" do
    test "approval.created event has correct type and payload" do
      event =
        Event.approval_created(
          %{
            approval_id: "appr_ev1",
            tool_call_id: "call_ev1",
            status: :pending
          },
          session_id: @session_id,
          metadata: %{correlation: %{task_id: @task_id}}
        )

      assert event.type == :"approval.created"
      assert event.payload.approval_id == "appr_ev1"
      assert event.payload.tool_call_id == "call_ev1"
      assert event.session_id == @session_id
    end

    test "approval.approved event has correct type and payload" do
      event =
        Event.approval_approved(
          %{
            approval_id: "appr_ev1",
            tool_call_id: "call_ev1",
            approver: "adam",
            rationale: "OK"
          },
          session_id: @session_id
        )

      assert event.type == :"approval.approved"
      assert event.payload.approver == "adam"
      assert event.payload.rationale == "OK"
    end

    test "approval.rejected event has correct type and payload" do
      event =
        Event.approval_rejected(
          %{
            approval_id: "appr_ev1",
            tool_call_id: "call_ev1",
            approver: "bob",
            rationale: "Too risky"
          },
          session_id: @session_id
        )

      assert event.type == :"approval.rejected"
      assert event.payload.approver == "bob"
      assert event.payload.rationale == "Too risky"
    end

    test "approval event types are in known_types" do
      known = Event.known_types()
      assert :"approval.created" in known
      assert :"approval.approved" in known
      assert :"approval.rejected" in known
    end

    test "approval_types/0 returns all three types" do
      types = Event.approval_types()
      assert :"approval.created" in types
      assert :"approval.approved" in types
      assert :"approval.rejected" in types
    end

    test "approval events serialize via Event.to_map/1" do
      event =
        Event.approval_created(
          %{approval_id: "a1", tool_call_id: "c1"},
          session_id: "ses1"
        )

      map = Event.to_map(event)
      assert map.type == "approval.created"
      assert map.session_id == "ses1"
      assert is_map(map.payload)
    end

    test "full approval lifecycle: created → approved event sequence" do
      created =
        Event.approval_created(
          %{approval_id: "a1", tool_call_id: "c1", status: :pending},
          session_id: "ses1",
          seq: 1
        )

      assert created.type == :"approval.created"

      approved =
        Event.approval_approved(
          %{approval_id: "a1", tool_call_id: "c1", approver: "adam", rationale: "OK"},
          session_id: "ses1",
          seq: 2
        )

      assert approved.type == :"approval.approved"
      # Same approval ID across lifecycle events
      assert created.payload.approval_id == approved.payload.approval_id
    end

    test "full approval lifecycle: created → rejected event sequence" do
      created =
        Event.approval_created(
          %{approval_id: "a2", tool_call_id: "c2"},
          session_id: "ses2"
        )

      rejected =
        Event.approval_rejected(
          %{approval_id: "a2", tool_call_id: "c2", approver: "bob", rationale: "No"},
          session_id: "ses2"
        )

      assert created.type == :"approval.created"
      assert rejected.type == :"approval.rejected"
      assert created.payload.approval_id == rejected.payload.approval_id
    end
  end

  describe "facade delegation" do
    test "Tet.Approval facade delegates to sub-modules" do
      alias Tet.Approval

      assert Approval.approval_statuses() == [:pending, :approved, :rejected]
      assert Approval.snapshot_actions() == [:taken_before, :taken_after]
      assert :no_active_task in Approval.known_block_reasons()

      # Compute hash via facade
      hash = Approval.compute_content_hash("hello")
      assert hash == Snapshot.compute_hash("hello")

      # New approval via facade
      assert {:ok, _} = Approval.new_approval(%{id: "f1", tool_call_id: "c1"})

      # New snapshot via facade
      assert {:ok, _} =
               Approval.new_snapshot(%{
                 id: "s1",
                 file_path: "/f",
                 content_hash: "h",
                 action: :taken_before
               })

      # New diff artifact via facade
      assert {:ok, _} =
               Approval.new_diff_artifact(%{
                 id: "d1",
                 tool_call_id: "c1",
                 file_path: "/f",
                 content_hash_before: "h1",
                 content_hash_after: "h2"
               })

      # New blocked action via facade
      assert {:ok, _} =
               Approval.new_blocked_action(%{
                 id: "b1",
                 tool_name: "t",
                 reason: :no_active_task,
                 tool_call_id: "c1"
               })

      # Blocked from gate via facade
      assert {:ok, _} =
               Approval.blocked_from_gate(
                 %{id: "b2", tool_name: "t", tool_call_id: "c2"},
                 {:block, :plan_mode_blocks_mutation}
               )
    end
  end

  describe "serialization round-trip: full audit story" do
    test "all four structs round-trip through to_map/from_map with correlation intact" do
      # Build all four records with shared correlation IDs
      {:ok, approval} =
        Approval.new(%{
          id: "appr_full",
          tool_call_id: @tool_call_id,
          status: :pending,
          session_id: @session_id,
          task_id: @task_id,
          metadata: %{tool_name: "write-file"}
        })

      {:ok, before_snap} =
        Snapshot.new(%{
          id: "snap_full_b",
          file_path: "/lib/app.ex",
          content_hash: "hash_b",
          action: :taken_before,
          tool_call_id: @tool_call_id,
          session_id: @session_id,
          task_id: @task_id
        })

      {:ok, after_snap} =
        Snapshot.new(%{
          id: "snap_full_a",
          file_path: "/lib/app.ex",
          content_hash: "hash_a",
          action: :taken_after,
          tool_call_id: @tool_call_id,
          session_id: @session_id,
          task_id: @task_id
        })

      {:ok, diff} =
        DiffArtifact.new(%{
          id: "diff_full",
          tool_call_id: @tool_call_id,
          file_path: "/lib/app.ex",
          content_hash_before: "hash_b",
          content_hash_after: "hash_a",
          snapshot_before_id: "snap_full_b",
          snapshot_after_id: "snap_full_a",
          session_id: @session_id,
          task_id: @task_id
        })

      {:ok, blocked} =
        BlockedAction.new(%{
          id: "blk_full",
          tool_name: "write-file",
          reason: :plan_mode_blocks_mutation,
          tool_call_id: @tool_call_id,
          session_id: @session_id,
          task_id: @task_id
        })

      # Round-trip all through serialization
      for {mod, record} <- [
            {Approval, approval},
            {Snapshot, before_snap},
            {Snapshot, after_snap},
            {DiffArtifact, diff},
            {BlockedAction, blocked}
          ] do
        map = mod.to_map(record)
        assert {:ok, restored} = mod.from_map(map)
        assert restored.id == record.id
        assert restored.tool_call_id == record.tool_call_id
        assert restored.session_id == record.session_id
        assert restored.task_id == record.task_id
      end
    end
  end
end
