defmodule Tet.Invariants.GuidanceAfterOperationsTest do
  @moduledoc """
  BD-0026 — Invariant 4: Guidance after task operations.

  Verifies that:
  - Guidance messages are emitted after task operations (start, activate,
    complete, recategorize, etc.)
  - Guidance type matches the active task category
  - Guidance content is meaningful and category-appropriate
  - Guidance transitions when category changes
  - No guidance when there's no active task
  - Gate-level guidance is emitted in plan-safe contexts
  - Fail-closed when policy category data is missing
  """

  use ExUnit.Case, async: true

  alias Tet.TaskManager
  alias Tet.TaskManager.{Guidance, Task}
  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Tool.ReadOnlyContracts

  import Tet.PlanMode.GateTestHelpers

  # -- Guidance after start_and_activate --

  describe "guidance after start_and_activate" do
    test "researching task produces research guidance" do
      state = TaskManager.new_state!(%{id: "tm_g1"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Research", category: :researching})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      assert {:guidance, :research, msg} = TaskManager.guidance(state)
      assert msg =~ "researching"
      assert Guidance.plan_safe?(:researching)
    end

    test "acting task produces act guidance" do
      state = TaskManager.new_state!(%{id: "tm_g2"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Implement", category: :acting})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      assert {:guidance, :act, msg} = TaskManager.guidance(state)
      assert msg =~ "acting"
    end

    test "planning task produces plan guidance" do
      state = TaskManager.new_state!(%{id: "tm_g3"})
      {:ok, state} = TaskManager.add_task(state, %{id: "t1", title: "Plan", category: :planning})
      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      assert {:guidance, :plan, msg} = TaskManager.guidance(state)
      assert msg =~ "planning"
    end

    test "verifying task produces verify guidance" do
      state = TaskManager.new_state!(%{id: "tm_g4"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Verify", category: :verifying})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      assert {:guidance, :verify, msg} = TaskManager.guidance(state)
      assert msg =~ "verification"
    end

    test "debugging task produces debug guidance" do
      state = TaskManager.new_state!(%{id: "tm_g5"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Debug", category: :debugging})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      assert {:guidance, :debug, msg} = TaskManager.guidance(state)
      assert msg =~ "debugging"
    end

    test "documenting task produces document guidance" do
      state = TaskManager.new_state!(%{id: "tm_g6"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Doc", category: :documenting})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      assert {:guidance, :document, msg} = TaskManager.guidance(state)
      assert msg =~ "documentation"
    end
  end

  # -- Guidance transitions with recategorize --

  describe "guidance transitions when category changes" do
    test "recategorize from researching to acting changes guidance" do
      state = TaskManager.new_state!(%{id: "tm_gc1"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Task", category: :researching})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      assert {:guidance, :research, _} = TaskManager.guidance(state)

      {:ok, state} = TaskManager.recategorize(state, "t1", :acting)
      assert {:guidance, :act, msg} = TaskManager.guidance(state)
      assert msg =~ "acting"
    end

    test "recategorize from acting to debugging changes guidance" do
      state = TaskManager.new_state!(%{id: "tm_gc2"})
      {:ok, state} = TaskManager.add_task(state, %{id: "t1", title: "Task", category: :acting})
      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      assert {:guidance, :act, _} = TaskManager.guidance(state)

      {:ok, state} = TaskManager.recategorize(state, "t1", :debugging)
      assert {:guidance, :debug, msg} = TaskManager.guidance(state)
      assert msg =~ "debugging"
    end
  end

  # -- No guidance when no active task --

  describe "no guidance when no active task" do
    test "fresh state returns :no_active_task" do
      state = TaskManager.new_state!(%{id: "tm_no"})
      assert :no_active_task = TaskManager.guidance(state)
    end

    test "after completing the only task, returns :no_active_task" do
      state = TaskManager.new_state!(%{id: "tm_no2"})
      {:ok, state} = TaskManager.add_task(state, %{id: "t1", title: "Task", category: :acting})
      {:ok, state} = TaskManager.start_and_activate(state, "t1")
      {:ok, state} = TaskManager.complete_task(state, "t1")
      assert :no_active_task = TaskManager.guidance(state)
    end

    test "guidance_for_category returns guidance even without active task" do
      # This is a category-level query, not state-dependent
      assert {:guidance, :research, _msg} = Guidance.for_category(:researching)
      assert {:guidance, :act, _msg} = Guidance.for_category(:acting)
    end
  end

  # -- Gate-level guidance in plan-safe contexts --

  describe "gate-level guidance for read-only tools in plan-safe contexts" do
    test "all read-only contracts produce guidance in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        assert Gate.guided?(decision),
               "#{contract.name} should emit guidance in plan/researching"
      end
    end

    test "all read-only contracts produce guidance in explore/planning" do
      ctx = %{mode: :explore, task_category: :planning, task_id: "t1"}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        assert Gate.guided?(decision),
               "#{contract.name} should emit guidance in explore/planning"
      end
    end

    test "read-only contracts in execute/acting do NOT emit guidance (flat :allow)" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        refute Gate.guided?(decision),
               "#{contract.name} should not emit guidance in execute/acting"
      end
    end

    test "guidance message mentions plan-mode research" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:guide, msg} = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert msg =~ "Plan-mode research allowed"
    end
  end

  # -- Guidance consistency between TaskManager and Gate --

  describe "guidance consistency between TaskManager and Gate" do
    test "plan-safe category guidance aligns with gate guidance" do
      state = TaskManager.new_state!(%{id: "tm_con"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Task", category: :researching})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      # TaskManager guidance
      {:guidance, :research, _} = TaskManager.guidance(state)

      # Gate guidance for read-only in plan/researching
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert Gate.guided?(decision)
    end
  end

  # -- All categories produce guidance content --

  describe "all categories produce non-empty guidance" do
    test "every task category has non-empty guidance message" do
      for cat <- Task.categories() do
        assert {:guidance, type, msg} = Guidance.for_category(cat)
        assert is_atom(type)
        assert is_binary(msg)
        assert byte_size(msg) > 0, "guidance for #{cat} is empty"
      end
    end
  end

  # -- Fail-closed guidance behavior --

  describe "fail closed: guidance with corrupted policy" do
    test "empty plan_safe_categories suppresses guidance in plan mode" do
      policy = empty_plan_safe_categories_policy()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, policy, ctx)

        refute Gate.guided?(decision),
               "#{contract.name} emitted guidance with empty plan_safe_categories"
      end
    end

    test "empty safe_modes suppresses guidance in plan mode" do
      policy = empty_safe_modes_policy()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, policy, ctx)

        refute Gate.guided?(decision),
               "#{contract.name} emitted guidance with empty safe_modes"
      end
    end
  end
end
