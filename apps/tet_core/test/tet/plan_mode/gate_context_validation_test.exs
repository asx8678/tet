defmodule Tet.PlanMode.GateContextValidationTest do
  @moduledoc """
  QA regression tests for plan-mode gate context validation.

  Split from gate_test.exs to keep files under 600 lines.
  Covers:
    - QA-1: contract_allows_category? prerequisite for read-only contracts
    - QA-2: malformed context returns deterministic block, never crashes
    - QA-3: omitted task_category with require_active_task: false (watchdog repro)
    - Facade coverage for invalid/relaxed-context scenarios
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}

  import Tet.PlanMode.GateTestHelpers

  # -- QA-1: read-only contract must declare runtime category --
  # The contract_allows_category? check is an independent prerequisite
  # BEFORE any read-only allow/guidance shortcut. If the contract's
  # task_categories omit the runtime category, block with :category_blocks_tool.

  describe "QA-1: contract_allows_category? prerequisite for read-only contracts" do
    test "read-only contract that omits runtime category is blocked in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_qa1a"}
      decision = Gate.evaluate(read_only_planning_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "read-only contract that omits runtime category is blocked in execute/acting" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_qa1b"}
      decision = Gate.evaluate(read_only_planning_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "read-only contract that declares runtime category is allowed in plan/planning" do
      ctx = %{mode: :plan, task_category: :planning, task_id: "t_qa1c"}
      decision = Gate.evaluate(read_only_planning_only_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "read-only contract that omits runtime category is blocked in execute/researching" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t_qa1d"}
      decision = Gate.evaluate(read_only_planning_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "mutating contract that omits runtime category is blocked even in execute/verifying" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_qa1e"}
      decision = Gate.evaluate(write_verifying_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    # -- Additional regression: explore mode --

    test "read-only contract that omits runtime category is blocked in explore/researching" do
      ctx = %{mode: :explore, task_category: :researching, task_id: "t_qa1f"}
      decision = Gate.evaluate(read_only_planning_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "read-only contract that declares runtime category is allowed in explore/planning" do
      ctx = %{mode: :explore, task_category: :planning, task_id: "t_qa1g"}
      decision = Gate.evaluate(read_only_planning_only_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    # -- Acting-only read-only contract regression --

    test "acting-only read-only contract is blocked in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_qa1h"}
      decision = Gate.evaluate(read_only_acting_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "acting-only read-only contract is blocked in plan/planning" do
      ctx = %{mode: :plan, task_category: :planning, task_id: "t_qa1i"}
      decision = Gate.evaluate(read_only_acting_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "acting-only read-only contract is allowed in execute/acting" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_qa1j"}
      decision = Gate.evaluate(read_only_acting_only_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "acting-only read-only contract is allowed in plan/acting (read-only shortcut)" do
      ctx = %{mode: :plan, task_category: :acting, task_id: "t_qa1k"}
      decision = Gate.evaluate(read_only_acting_only_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "acting-only read-only contract is blocked in execute/researching" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t_qa1l"}
      decision = Gate.evaluate(read_only_acting_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "acting-only read-only contract is blocked in explore/researching" do
      ctx = %{mode: :explore, task_category: :researching, task_id: "t_qa1m"}
      decision = Gate.evaluate(read_only_acting_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end
  end

  # -- QA-2: malformed context never crashes, returns deterministic block --

  describe "QA-2: malformed context returns deterministic block, never crashes" do
    test "missing :mode key returns {:block, :invalid_context}" do
      ctx = %{task_category: :researching, task_id: "t_qa2a"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :invalid_context} = decision
    end

    test "nil :mode returns {:block, :invalid_context}" do
      ctx = %{mode: nil, task_category: :researching, task_id: "t_qa2b"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :invalid_context} = decision
    end

    test "non-atom :mode returns {:block, :invalid_context}" do
      ctx = %{mode: "plan", task_category: :researching, task_id: "t_qa2c"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :invalid_context} = decision
    end

    test "non-atom :mode (integer) returns {:block, :invalid_context}" do
      ctx = %{mode: 42, task_category: :researching, task_id: "t_qa2d"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :invalid_context} = decision
    end

    test "missing :task_category with require_active_task false returns {:block, :invalid_context}" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: :plan, task_id: "t_qa2e"}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      assert {:block, :invalid_context} = decision
    end

    test "nil :task_category with require_active_task false returns {:block, :invalid_context}" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: :plan, task_category: nil, task_id: "t_qa2f"}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      assert {:block, :invalid_context} = decision
    end

    test "missing :task_category with require_active_task false for mutating contract" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: :execute, task_id: "t_qa2g"}
      decision = Gate.evaluate(write_contract(), policy, ctx)
      assert {:block, :invalid_context} = decision
    end

    test "nil :task_category with require_active_task false for mutating contract" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: :execute, task_category: nil, task_id: "t_qa2h"}
      decision = Gate.evaluate(write_contract(), policy, ctx)
      assert {:block, :invalid_context} = decision
    end

    test "empty context returns {:block, :invalid_context}" do
      decision = Gate.evaluate(read_contract(), Policy.new!(%{require_active_task: false}), %{})
      assert {:block, :invalid_context} = decision
    end

    test "valid mode but invalid :mode for mutating contract" do
      ctx = %{mode: "execute", task_category: :acting, task_id: "t_qa2i"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :invalid_context} = decision
    end

    test "valid mode, missing category key for read-only contract with require_active_task false" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: :explore, task_id: "t_qa2j"}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      assert {:block, :invalid_context} = decision
    end
  end

  # -- QA-3: watchdog repro — omitted task_category with require_active_task: false --
  # Original crash: FunctionClauseError when task_category omitted from context
  # and require_active_task: false. Gate now returns deterministic
  # {:block, :invalid_context} — never crashes.

  describe "QA-3: watchdog repro — omitted task_category with require_active_task false" do
    test "read-only contract, plan mode, no task_category — deterministic block" do
      # Exact watchdog repro from review:
      # Policy.new!(%{require_active_task: false}); Gate.evaluate(read, policy, %{mode: :plan})
      decision = Gate.evaluate(read_contract(), relaxed_policy(), %{mode: :plan})
      assert {:block, :invalid_context} = decision
    end

    test "read-only contract, explore mode, no task_category — deterministic block" do
      decision = Gate.evaluate(read_contract(), relaxed_policy(), %{mode: :explore})
      assert {:block, :invalid_context} = decision
    end

    test "read-only contract, execute mode, no task_category — deterministic block" do
      decision = Gate.evaluate(read_contract(), relaxed_policy(), %{mode: :execute})
      assert {:block, :invalid_context} = decision
    end

    test "mutating contract, execute mode, no task_category — deterministic block" do
      decision = Gate.evaluate(write_contract(), relaxed_policy(), %{mode: :execute})
      assert {:block, :invalid_context} = decision
    end

    test "mutating contract, plan mode, no task_category — deterministic block (mode gate first)" do
      # write_contract declares only [:execute, :repair] — :plan is not a declared
      # mode, so check_contract_mode blocks with :mode_not_allowed before
      # category gate is reached. This is correct: gate checks are ordered.
      decision = Gate.evaluate(write_contract(), relaxed_policy(), %{mode: :plan})
      assert {:block, :mode_not_allowed} = decision
    end

    test "nil task_category with require_active_task false, read-only, plan mode" do
      decision =
        Gate.evaluate(read_contract(), relaxed_policy(), %{mode: :plan, task_category: nil})

      assert {:block, :invalid_context} = decision
    end

    test "nil task_category with require_active_task false, mutating, execute mode" do
      decision =
        Gate.evaluate(write_contract(), relaxed_policy(), %{mode: :execute, task_category: nil})

      assert {:block, :invalid_context} = decision
    end

    test "non-atom task_category with require_active_task false — deterministic block" do
      decision =
        Gate.evaluate(read_contract(), relaxed_policy(), %{
          mode: :plan,
          task_category: "researching"
        })

      assert {:block, :invalid_context} = decision
    end
  end

  # -- Facade coverage for invalid/relaxed context --

  describe "facade delegates for invalid context" do
    test "PlanMode.evaluate returns {:block, :invalid_context} for missing :mode" do
      ctx = %{task_category: :researching, task_id: "t_fac1"}
      decision = Tet.PlanMode.evaluate(read_contract(), ctx)
      assert {:block, :invalid_context} = decision
    end

    test "PlanMode.evaluate returns {:block, :invalid_context} for nil :task_category with relaxed policy" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: :plan, task_category: nil}
      decision = Tet.PlanMode.evaluate(read_contract(), policy, ctx)
      assert {:block, :invalid_context} = decision
    end

    test "PlanMode.evaluate returns {:block, :invalid_context} for omitted :task_category with relaxed policy" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: :plan}
      decision = Tet.PlanMode.evaluate(read_contract(), policy, ctx)
      assert {:block, :invalid_context} = decision
    end

    test "PlanMode.evaluate returns {:block, :invalid_context} for empty context with relaxed policy" do
      policy = Policy.new!(%{require_active_task: false})
      decision = Tet.PlanMode.evaluate(read_contract(), policy, %{})
      assert {:block, :invalid_context} = decision
    end
  end
end
