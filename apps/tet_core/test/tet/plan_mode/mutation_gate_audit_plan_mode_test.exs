defmodule Tet.PlanMode.MutationGateAuditPlanModeTest do
  @moduledoc """
  BD-0030: Mutation gate audit tests — plan mode blocking.

  Verifies that:
    2. Mutating tools in plan mode with plan-safe category are blocked
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}

  import Tet.PlanMode.GateTestHelpers
  import Tet.PlanMode.MutationGateAuditTestHelpers

  # ============================================================
  # 2. Mutating tools in plan mode with plan-safe category blocked
  # ============================================================

  describe "2: mutating tools in plan mode with plan-safe category are blocked" do
    test "write contract blocked in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_pr"}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)

      assert {:block, :plan_mode_blocks_mutation} = decision

      assert {:ok, event} = persist_decision(rogue_plan_write_contract(), decision)
      assert event.type == :"tool.blocked"
      assert event.payload.decision == {:block, :plan_mode_blocks_mutation}
    end

    test "write contract blocked in plan/planning" do
      ctx = %{mode: :plan, task_category: :planning, task_id: "t_pp"}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)

      assert {:block, :plan_mode_blocks_mutation} = decision
    end

    test "shell contract blocked in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_pr_shell"}
      decision = Gate.evaluate(rogue_plan_shell_contract(), Policy.default(), ctx)

      assert {:block, :plan_mode_blocks_mutation} = decision
    end

    test "shell-type contract blocked in explore/researching" do
      # rogue_plan_write_contract declares [:plan, :explore, :execute] in modes,
      # so :explore passes check_contract_mode. It is still non-read-only,
      # so the plan-mode gate blocks it.
      ctx = %{mode: :explore, task_category: :researching, task_id: "t_er_mutation"}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)

      assert {:block, :plan_mode_blocks_mutation} = decision
    end

    test "rogue write contract that declares plan mode still blocked" do
      # A contract that sneakily declares :plan in modes should still be
      # blocked because the gate's plan-mode check is policy-driven.
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_rogue"}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)

      assert {:block, :plan_mode_blocks_mutation} = decision

      assert {:ok, event} = persist_decision(rogue_plan_write_contract(), decision)
      assert event.type == :"tool.blocked"
    end

    test "rogue write contract blocked in explore/planning too" do
      ctx = %{mode: :explore, task_category: :planning, task_id: "t_rogue_exp"}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)

      assert {:block, :plan_mode_blocks_mutation} = decision
    end

    test "write contract blocked in ALL plan-safe mode/category combos" do
      for mode <- [:plan, :explore],
          category <- [:researching, :planning] do
        ctx = %{mode: mode, task_category: category, task_id: "t_sweep"}

        # Use rogue contracts that declare plan/explore modes so the
        # plan-mode gate actually fires (vs mode_not_allowed).
        for contract <- [rogue_plan_write_contract(), rogue_plan_shell_contract()] do
          decision = Gate.evaluate(contract, Policy.default(), ctx)

          assert Gate.blocked?(decision),
                 "#{contract.name} should be blocked in #{mode}/#{category}, got #{inspect(decision)}"
        end
      end
    end

    test "write contract blocked in plan mode even with acting category" do
      # Plan mode gates mutation regardless of category — the mode check
      # runs before category evaluation.
      ctx = %{mode: :plan, task_category: :acting, task_id: "t_plan_act"}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)

      # Rogue contract declares :plan in modes, so it passes check_contract_mode.
      # Plan-safe mode + non-read-only = :plan_mode_blocks_mutation.
      assert {:block, :plan_mode_blocks_mutation} = decision
    end
  end
end
