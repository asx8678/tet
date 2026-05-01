defmodule Tet.PlanMode.MutationGateAuditTaskTest do
  @moduledoc """
  BD-0030: Mutation gate audit tests — active task requirements & missing task edges.

  Verifies that:
    1. Mutating tools require an active acting or verifying task
    6a. Edge cases around missing/invalid task fields
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}

  import Tet.PlanMode.GateTestHelpers
  import Tet.PlanMode.MutationGateAuditTestHelpers

  # ============================================================
  # 1. Mutating tools require active acting or verifying task
  # ============================================================

  describe "1: mutating tools require active acting or verifying task" do
    test "write contract blocked without active task (nil task_id)" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

      assert {:block, :no_active_task} = decision

      assert {:ok, event} = persist_decision(write_contract(), decision)
      assert event.type == :"tool.blocked"
      assert event.payload.decision == {:block, :no_active_task}
      assert event.payload.mutation == :write
    end

    test "shell contract blocked without active task (empty task_id)" do
      ctx = %{mode: :execute, task_category: :acting, task_id: ""}
      decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)

      assert {:block, :no_active_task} = decision

      assert {:ok, event} = persist_decision(shell_contract(), decision)
      assert event.type == :"tool.blocked"
    end

    test "write contract blocked when task_category is nil" do
      ctx = %{mode: :execute, task_category: nil, task_id: "t_valid"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

      assert {:block, :no_active_task} = decision
    end

    test "write contract allowed with acting task" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_act"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

      assert Gate.allowed?(decision)

      assert {:ok, event} = persist_decision(write_contract(), decision)
      assert event.type == :"tool.started"
      assert event.payload.decision == :allow
    end

    test "write contract allowed with verifying task" do
      ctx = %{mode: :execute, task_category: :verifying, task_id: "t_verify"}
      decision = Gate.evaluate(write_acting_verifying_contract(), Policy.default(), ctx)

      assert Gate.allowed?(decision)

      assert {:ok, event} = persist_decision(write_acting_verifying_contract(), decision)
      assert event.type == :"tool.started"
    end

    test "write contract blocked with researching task (plan-safe)" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t_res"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

      assert Gate.blocked?(decision)

      assert {:ok, event} = persist_decision(write_contract(), decision)
      assert event.type == :"tool.blocked"
    end

    test "write contract blocked with planning task (plan-safe)" do
      ctx = %{mode: :execute, task_category: :planning, task_id: "t_plan"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

      assert Gate.blocked?(decision)

      assert {:ok, event} = persist_decision(write_contract(), decision)
      assert event.type == :"tool.blocked"
    end

    test "shell contract blocked with researching task even in execute mode" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t_shell_res"}
      decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)

      assert Gate.blocked?(decision)
    end

    test "all mutating contracts blocked when task_id missing with default policy" do
      mutating_contracts = [write_contract(), shell_contract()]

      for contract <- mutating_contracts,
          category <- [:researching, :planning, :acting, :verifying] do
        ctx = %{mode: :execute, task_category: category, task_id: nil}
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        assert Gate.blocked?(decision),
               "#{contract.name} should be blocked without task_id in execute/#{category}"
      end
    end
  end

  # ============================================================
  # 6a. Edge case — missing task
  # ============================================================

  describe "6a: edge case — missing task" do
    test "task_id omitted from context blocks mutating tool" do
      ctx = %{mode: :execute, task_category: :acting}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision

      assert {:ok, event} = persist_decision(write_contract(), decision)
      assert event.type == :"tool.blocked"
    end

    test "task_category omitted from context blocks mutating tool" do
      ctx = %{mode: :execute, task_id: "t_miss_cat"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "both task_id and task_category omitted" do
      ctx = %{mode: :execute}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "task_id is non-binary (integer)" do
      ctx = %{mode: :execute, task_category: :acting, task_id: 42}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "task_category is non-atom (string)" do
      ctx = %{mode: :execute, task_category: "acting", task_id: "t_str_cat"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end
  end
end
