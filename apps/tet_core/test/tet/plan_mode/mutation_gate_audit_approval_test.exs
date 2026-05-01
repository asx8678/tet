defmodule Tet.PlanMode.MutationGateAuditApprovalTest do
  @moduledoc """
  BD-0030: Mutation gate audit tests — approval flow.

  Verifies that:
    3. Approval flow — blocked mutations persist the block event;
       approved mutations persist the approval event
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}

  import Tet.PlanMode.GateTestHelpers
  import Tet.PlanMode.MutationGateAuditTestHelpers

  # ============================================================
  # 3. Approval flow — blocked and approved events both persisted
  # ============================================================

  describe "3: approval flow — blocked and approved events both persisted" do
    test "blocked mutation produces tool.blocked event with reason" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_blocked_flow"}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)

      assert {:block, reason} = decision
      assert reason == :plan_mode_blocks_mutation

      assert {:ok, event} = persist_decision(rogue_plan_write_contract(), decision)
      assert event.type == :"tool.blocked"
      assert event.payload.tool == "rogue-plan-write"
      assert event.payload.decision == {:block, :plan_mode_blocks_mutation}
      assert event.payload.mutation == :write
      assert event.payload.read_only == false
    end

    test "approved mutation produces tool.started event with :allow decision" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_approved_flow"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

      assert decision == :allow

      assert {:ok, event} = persist_decision(write_contract(), decision)
      assert event.type == :"tool.started"
      assert event.payload.tool == "write-file"
      assert event.payload.decision == :allow
      assert event.payload.mutation == :write
      assert event.payload.read_only == false
    end

    test "blocked mutation from no_active_task produces auditable event" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)

      assert {:block, :no_active_task} = decision

      assert {:ok, event} = persist_decision(shell_contract(), decision)
      assert event.type == :"tool.blocked"
      assert event.payload.decision == {:block, :no_active_task}
      assert event.payload.tool == "shell"
    end

    test "blocked mutation from category_blocks_tool produces auditable event" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_cat_block"}
      decision = Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx)

      assert {:block, :category_blocks_tool} = decision

      assert {:ok, event} = persist_decision(verifying_only_write_contract(), decision)
      assert event.type == :"tool.blocked"
      assert event.payload.decision == {:block, :category_blocks_tool}
    end

    test "blocked mutation from mode_not_allowed produces auditable event" do
      # write_contract only declares [:execute, :repair] modes, so :plan is rejected
      ctx = %{mode: :plan, task_category: :acting, task_id: "t_mode_block"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

      assert {:block, :mode_not_allowed} = decision

      assert {:ok, event} = persist_decision(write_contract(), decision)
      assert event.type == :"tool.blocked"
      assert event.payload.decision == {:block, :mode_not_allowed}
    end

    test "full audit trail: blocked → approved transition for same tool" do
      # First: blocked attempt in plan mode (use rogue contract that declares plan mode)
      blocked_ctx = %{mode: :plan, task_category: :researching, task_id: "t_transition"}
      blocked_decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), blocked_ctx)
      assert Gate.blocked?(blocked_decision)

      assert {:ok, blocked_event} =
               persist_decision(rogue_plan_write_contract(), blocked_decision)

      assert blocked_event.type == :"tool.blocked"

      # Then: approved after transitioning to execute/acting
      approved_ctx = %{mode: :execute, task_category: :acting, task_id: "t_transition"}
      approved_decision = Gate.evaluate(write_contract(), Policy.default(), approved_ctx)
      assert Gate.allowed?(approved_decision)

      assert {:ok, approved_event} = persist_decision(write_contract(), approved_decision)
      assert approved_event.type == :"tool.started"

      # Both events capture mutation attempts — the audit trail is complete
      assert blocked_event.payload.mutation == :write
      assert approved_event.payload.mutation == :write
    end

    test "multiple blocked attempts each produce distinct auditable events" do
      # Three distinct block reasons from different contexts
      blocked_scenarios = [
        {%{mode: :plan, task_category: :researching, task_id: "t1"}, rogue_plan_write_contract(),
         "plan mode blocks mutation"},
        {%{mode: :execute, task_category: :researching, task_id: "t2"}, write_contract(),
         "plan-safe category blocks tool"},
        {%{mode: :execute, task_category: :acting, task_id: nil}, write_contract(),
         "no active task"}
      ]

      reasons =
        for {ctx, contract, description} <- blocked_scenarios do
          decision = Gate.evaluate(contract, Policy.default(), ctx)
          assert Gate.blocked?(decision), "Expected block for #{description}"

          assert {:ok, event} = persist_decision(contract, decision)
          assert event.type == :"tool.blocked"

          decision
        end

      # All three blocked attempts produce different block reasons
      unique_reasons = reasons |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      assert length(unique_reasons) == 3,
             "Expected 3 distinct block reasons, got #{inspect(unique_reasons)}"
    end
  end
end
