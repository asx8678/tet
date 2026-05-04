defmodule Tet.Invariants.NoMutationWithoutTaskTest do
  @moduledoc """
  BD-0026 — Invariant 1: No mutating/executing tool without an active task.

  Verifies that write, edit, patch, and shell tools are blocked when no
  active task exists. Also tests fail-closed behavior when policy data is
  missing or malformed.

  Mutating tools are modeled as non-read-only contracts built from the
  test helper fixtures. The gate is evaluated with nil/empty task context
  to confirm the invariant holds.
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.TaskManager

  import Tet.PlanMode.GateTestHelpers

  # -- All mutating tool types blocked without active task --

  describe "write/edit/patch/shell blocked without active task" do
    test "write contract blocked when task_id is nil" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "shell contract blocked when task_id is nil" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "write contract blocked when task_id is empty string" do
      ctx = %{mode: :execute, task_category: :acting, task_id: ""}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "shell contract blocked when task_id is empty string" do
      ctx = %{mode: :execute, task_category: :acting, task_id: ""}
      decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "write contract blocked when task_id is omitted entirely" do
      ctx = %{mode: :execute, task_category: :acting}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "shell contract blocked when task_id is omitted entirely" do
      ctx = %{mode: :execute, task_category: :acting}
      decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "write contract blocked when task_category is nil" do
      ctx = %{mode: :execute, task_category: nil, task_id: "t1"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "shell contract blocked when task_category is nil" do
      ctx = %{mode: :execute, task_category: nil, task_id: "t1"}
      decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "write contract blocked when both task_id and task_category are nil" do
      ctx = %{mode: :execute, task_category: nil, task_id: nil}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end
  end

  # -- Rogue mutating contracts (declaring :plan mode) also blocked --

  describe "rogue mutating contracts blocked without active task" do
    test "rogue-plan-write blocked when task_id is nil" do
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "rogue-plan-shell blocked when task_id is nil" do
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(rogue_plan_shell_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end
  end

  # -- Read-only tools also blocked without active task (fail-closed) --

  describe "read-only tools also blocked without active task" do
    test "read contract blocked when task_id is nil" do
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "all read-only contracts blocked when task_id is nil" do
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}

      for contract <- Tet.Tool.ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        assert Tet.PlanMode.Gate.blocked?(decision),
               "#{contract.name} should be blocked without active task"
      end
    end
  end

  # -- Mutating tools allowed WITH active task --

  describe "mutating tools allowed with active task" do
    test "write contract allowed in execute/acting with valid task" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "shell contract allowed in execute/acting with valid task" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end
  end

  # -- TaskManager integration: no active task = nil category --

  describe "TaskManager: no active task produces nil category" do
    test "fresh state has nil active_category" do
      state = TaskManager.new_state!(%{id: "tm_no_task"})
      assert TaskManager.active_category(state) == nil
      assert TaskManager.active_task(state) == nil
    end

    test "after completing the only task, active_category returns nil" do
      state = TaskManager.new_state!(%{id: "tm_complete"})
      {:ok, state} = TaskManager.add_task(state, %{id: "t1", title: "Test", category: :acting})
      {:ok, state} = TaskManager.start_and_activate(state, "t1")
      {:ok, state} = TaskManager.complete_task(state, "t1")
      assert TaskManager.active_category(state) == nil
    end
  end

  # -- Fail-closed with corrupted policy data --

  describe "fail closed: missing policy data blocks mutation" do
    test "empty safe_modes policy still blocks mutation without active task" do
      policy = empty_safe_modes_policy()
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(write_contract(), policy, ctx)
      assert Gate.blocked?(decision)
    end

    test "nil safe_modes policy still blocks mutation without active task" do
      policy = nil_safe_modes_policy()
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      decision = Gate.evaluate(shell_contract(), policy, ctx)
      assert Gate.blocked?(decision)
    end

    test "all-nil policy fields block all mutating tools" do
      policy =
        struct(Tet.PlanMode.Policy, %{
          plan_mode: :plan,
          safe_modes: nil,
          plan_safe_categories: nil,
          acting_categories: nil,
          require_active_task: true
        })

      for contract <- [write_contract(), shell_contract()],
          task_id <- [nil, "", 42, :atom] do
        ctx = %{mode: :execute, task_category: :acting, task_id: task_id}
        decision = Gate.evaluate(contract, policy, ctx)

        assert Gate.blocked?(decision),
               "nil policy allowed mutation for #{contract.name} with task_id #{inspect(task_id)}"
      end
    end
  end
end
