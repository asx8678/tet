defmodule Tet.PlanMode.MutationGateAuditEdgeCasesTest do
  @moduledoc """
  BD-0030: Mutation gate audit tests — edge cases.

  Verifies that:
    6b. Missing category in contract
    6c. Corrupted policy
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Tool.Contract

  import Tet.PlanMode.GateTestHelpers
  import Tet.PlanMode.MutationGateAuditTestHelpers

  # ============================================================
  # 6b. Edge case — missing category in contract
  # ============================================================

  describe "6b: edge case — missing category in contract" do
    test "contract with empty task_categories blocked in all contexts" do
      # Manually construct a contract with empty task_categories
      %Contract{} = base = read_contract()

      empty_cat_contract = %{
        base
        | name: "empty-cat-write",
          read_only: false,
          mutation: :write,
          modes: [:execute, :repair],
          task_categories: [],
          execution: %{
            base.execution
            | mutates_workspace: true,
              executes_code: false,
              status: :contract_only,
              effects: [:writes_file]
          }
      }

      for category <- [:acting, :verifying, :researching, :planning] do
        ctx = %{mode: :execute, task_category: category, task_id: "t_empty_cat"}
        decision = Gate.evaluate(empty_cat_contract, Policy.default(), ctx)

        assert Gate.blocked?(decision),
               "empty-cat-write should be blocked in execute/#{category}, got #{inspect(decision)}"
      end
    end

    test "contract that omits acting/verifying from task_categories is blocked for acting context" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_no_act"}
      decision = Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx)

      assert {:block, :category_blocks_tool} = decision

      assert {:ok, event} = persist_decision(verifying_only_write_contract(), decision)
      assert event.type == :"tool.blocked"
    end
  end

  # ============================================================
  # 6c. Edge case — corrupted policy
  # ============================================================

  describe "6c: edge case — corrupted policy" do
    test "nil safe_modes + nil acting_categories policy never allows mutation" do
      # Use a policy with both nil safe_modes AND nil acting_categories
      # so that execute/acting also fails closed
      policy =
        struct(Policy, %{
          plan_mode: :plan,
          safe_modes: nil,
          plan_safe_categories: [:researching, :planning],
          acting_categories: nil,
          require_active_task: true
        })

      for mode <- [:plan, :explore, :execute],
          category <- [:researching, :planning, :acting],
          contract <- [write_contract(), shell_contract()] do
        ctx = %{mode: mode, task_category: category, task_id: "t_corrupt"}
        decision = Gate.evaluate(contract, policy, ctx)

        assert Gate.blocked?(decision),
               "corrupted policy allowed #{contract.name} in #{mode}/#{category}: #{inspect(decision)}"
      end
    end

    test "nil acting_categories policy restricts mutation in execute mode" do
      policy =
        struct(Policy, %{
          plan_mode: :plan,
          safe_modes: [:plan, :explore],
          plan_safe_categories: [:researching, :planning],
          acting_categories: nil,
          require_active_task: true
        })

      ctx = %{mode: :execute, task_category: :acting, task_id: "t_nil_act"}
      decision = Gate.evaluate(write_contract(), policy, ctx)
      assert Gate.blocked?(decision)
    end

    test "fully corrupted policy (all nils) blocks all mutations" do
      policy =
        struct(Policy, %{
          plan_mode: nil,
          safe_modes: nil,
          plan_safe_categories: nil,
          acting_categories: nil,
          require_active_task: true
        })

      for contract <- [write_contract(), shell_contract()] do
        ctx = %{mode: :execute, task_category: :acting, task_id: "t_full_corrupt"}
        decision = Gate.evaluate(contract, policy, ctx)

        assert Gate.blocked?(decision),
               "fully corrupted policy allowed #{contract.name}: #{inspect(decision)}"
      end
    end

    test "corrupted policy blocked decisions are still persistable as events" do
      policy =
        struct(Policy, %{
          plan_mode: nil,
          safe_modes: nil,
          plan_safe_categories: nil,
          acting_categories: nil,
          require_active_task: true
        })

      ctx = %{mode: :execute, task_category: :acting, task_id: "t_persist_corrupt"}
      decision = Gate.evaluate(write_contract(), policy, ctx)

      assert Gate.blocked?(decision)

      assert {:ok, event} = persist_decision(write_contract(), decision)
      assert event.type == :"tool.blocked"
      assert match?({:block, _}, event.payload.decision)
    end

    test "empty safe_modes policy blocks even read-only with invalid context" do
      policy = empty_safe_modes_policy()
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(read_contract(), policy, ctx)

      assert Gate.blocked?(decision)
    end
  end
end
