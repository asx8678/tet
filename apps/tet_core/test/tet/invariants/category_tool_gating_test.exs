defmodule Tet.Invariants.CategoryToolGatingTest do
  @moduledoc """
  BD-0026 — Invariant 2: Category-based tool gating.

  Verifies that:
  - researching/planning categories only allow read-only tools
  - acting/verifying/debugging/documenting categories allow mutating tools
  - Category gating is enforced consistently across plan and execute modes
  - Fail-closed behavior when policy category data is missing
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.TaskManager
  alias Tet.Tool.ReadOnlyContracts

  import Tet.PlanMode.GateTestHelpers

  # -- Plan-safe categories block mutating tools in plan mode --

  describe "researching/planning block mutating tools in plan mode" do
    test "write blocked in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "write blocked in plan/planning" do
      ctx = %{mode: :plan, task_category: :planning, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "shell blocked in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(shell_contract(), Policy.default(), ctx))
    end

    test "shell blocked in plan/planning" do
      ctx = %{mode: :plan, task_category: :planning, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(shell_contract(), Policy.default(), ctx))
    end

    test "write blocked in explore/researching" do
      ctx = %{mode: :explore, task_category: :researching, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "shell blocked in explore/planning" do
      ctx = %{mode: :explore, task_category: :planning, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(shell_contract(), Policy.default(), ctx))
    end
  end

  # -- Plan-safe categories allow read-only tools --

  describe "researching/planning allow read-only tools" do
    test "read allowed in plan/researching with guidance" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
      assert Gate.guided?(decision)
    end

    test "list allowed in plan/planning with guidance" do
      ctx = %{mode: :plan, task_category: :planning, task_id: "t1"}
      decision = Gate.evaluate(list_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "all read-only contracts allowed in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        assert Gate.allowed?(decision),
               "#{contract.name} should be allowed in plan/researching"
      end
    end

    test "all read-only contracts allowed in plan/planning" do
      ctx = %{mode: :plan, task_category: :planning, task_id: "t1"}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        assert Gate.allowed?(decision),
               "#{contract.name} should be allowed in plan/planning"
      end
    end
  end

  # -- Acting categories allow mutating tools in execute mode --

  describe "acting categories allow mutating tools in execute mode" do
    test "write allowed in execute/acting" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      assert Gate.allowed?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "shell allowed in execute/acting" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      assert Gate.allowed?(Gate.evaluate(shell_contract(), Policy.default(), ctx))
    end

    test "write allowed in execute/verifying (with matching contract)" do
      ctx = %{mode: :execute, task_category: :verifying, task_id: "t1"}
      assert Gate.allowed?(Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx))
    end

    test "shell allowed in execute/debugging" do
      # shell_contract has task_categories [:acting, :debugging]
      ctx = %{mode: :execute, task_category: :debugging, task_id: "t1"}
      assert Gate.allowed?(Gate.evaluate(shell_contract(), Policy.default(), ctx))
    end
  end

  # -- Acting categories still restricted in plan mode --

  describe "acting categories still restricted in plan mode" do
    test "write blocked even with acting category in plan mode" do
      ctx = %{mode: :plan, task_category: :acting, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "shell blocked even with acting category in plan mode" do
      ctx = %{mode: :plan, task_category: :acting, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(shell_contract(), Policy.default(), ctx))
    end

    test "read-only allowed with acting category in plan mode (no guidance)" do
      ctx = %{mode: :plan, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
      refute Gate.guided?(decision)
    end
  end

  # -- Plan-safe categories block mutation even in execute mode --

  describe "plan-safe categories block mutation even in execute mode" do
    test "write blocked in execute/researching" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "write blocked in execute/planning" do
      ctx = %{mode: :execute, task_category: :planning, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "shell blocked in execute/researching" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(shell_contract(), Policy.default(), ctx))
    end

    test "read-only still allowed in execute/researching" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end
  end

  # -- All six categories produce deterministic gate outcomes --

  describe "all six categories produce deterministic gate outcomes" do
    test "write contract: blocked in plan-safe, allowed in acting (execute mode)" do
      plan_safe_cats = Policy.plan_safe_categories()
      acting_cats = Policy.acting_categories()

      for category <- plan_safe_cats do
        ctx = %{mode: :plan, task_category: category, task_id: "t_cat"}
        decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

        assert Gate.blocked?(decision),
               "write should be blocked in plan/#{category}"
      end

      for category <- acting_cats do
        # write_contract declares task_categories: [:acting, :verifying, :debugging]
        if Policy.contract_allows_category?(write_contract(), category) do
          ctx = %{mode: :execute, task_category: category, task_id: "t_cat"}
          decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

          assert Gate.allowed?(decision),
                 "write should be allowed in execute/#{category}"
        end
      end
    end
  end

  # -- Contract-declared category enforcement --

  describe "contract-declared category enforcement" do
    test "verifying-only write contract blocked in execute/acting" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "verifying-only write contract allowed in execute/verifying" do
      ctx = %{mode: :execute, task_category: :verifying, task_id: "t1"}
      decision = Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "unknown category blocks even read-only" do
      ctx = %{mode: :execute, task_category: :unknown_category, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert Gate.blocked?(decision)
    end
  end

  # -- TaskManager category queries validate gating consistency --

  describe "TaskManager category queries" do
    test "plan_safe? matches Policy.plan_safe_category?" do
      for cat <- TaskManager.categories() do
        assert Tet.TaskManager.Guidance.plan_safe?(cat) ==
                 Policy.plan_safe_category?(Policy.default(), cat),
               "plan_safe? mismatch for #{cat}"
      end
    end

    test "acting? matches Policy.acting_category?" do
      for cat <- TaskManager.categories() do
        assert Tet.TaskManager.Guidance.acting?(cat) ==
                 Policy.acting_category?(Policy.default(), cat),
               "acting? mismatch for #{cat}"
      end
    end
  end

  # -- Fail-closed with corrupted policy category data --

  describe "fail closed: missing category policy data" do
    test "nil acting_categories blocks mutation in execute mode" do
      policy =
        struct(Policy, %{
          plan_mode: :plan,
          safe_modes: [:plan, :explore],
          plan_safe_categories: [:researching, :planning],
          acting_categories: nil,
          require_active_task: true
        })

      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(write_contract(), policy, ctx)
      assert Gate.blocked?(decision)
    end

    test "empty plan_safe_categories still blocks mutation in plan mode" do
      policy = empty_plan_safe_categories_policy()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(write_contract(), policy, ctx)
      assert Gate.blocked?(decision)
    end

    test "nil plan_safe_categories does not emit guidance" do
      policy =
        struct(Policy, %{
          plan_mode: :plan,
          safe_modes: [:plan, :explore],
          plan_safe_categories: nil,
          acting_categories: [:acting],
          require_active_task: true
        })

      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, policy, ctx)

        refute Gate.guided?(decision),
               "#{contract.name} got guidance with nil plan_safe_categories"
      end
    end
  end
end
