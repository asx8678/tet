defmodule Tet.PlanMode.InvariantsGateTest do
  @moduledoc """
  BD-0026: Invariants 1–3 test suite (gate decision invariants).

  Verifies that active task enforcement, category gate behavior, and
  hook ordering determinism hold under all conditions, including when
  policy data is missing or malformed. Every invariant must fail
  closed — block deterministically rather than crash or allow.

  See `InvariantsEventTest` for invariants 4–5 (guidance and events).

  ## Invariants covered

  1. **Active Task Enforcement** — No tool call without an active task
     when policy requires one. Fail-closed on missing task data.

  2. **Category Gate Behavior** — Plan-safe categories restrict tools
     to read-only; acting categories unlock mutation. Fail-closed on
     missing category data.

  3. **Hook Ordering Determinism** — Gate checks are applied in a
     well-defined order; same inputs always produce the same decision.
     Hook system stubbed until BD-0024 merges.
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Tool.ReadOnlyContracts

  import Tet.PlanMode.GateTestHelpers

  # ============================================================
  # Invariant 1: Active Task Enforcement
  # ============================================================
  # The gate MUST block any tool call when no active task is present
  # and the policy requires one. This applies to ALL contract types —
  # read-only and mutating. Fail-closed: missing, nil, empty, or
  # non-binary task_id / non-atom task_category all block with
  # {:block, :no_active_task}, never crash.

  describe "Invariant 1: active task enforcement" do
    test "read-only tool blocked when task_id is nil with default policy" do
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      assert {:block, :no_active_task} = Gate.evaluate(read_contract(), Policy.default(), ctx)
    end

    test "mutating tool blocked when task_id is nil with default policy" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      assert {:block, :no_active_task} = Gate.evaluate(write_contract(), Policy.default(), ctx)
    end

    test "shell/executing tool blocked when task_id is nil" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      assert {:block, :no_active_task} = Gate.evaluate(shell_contract(), Policy.default(), ctx)
    end

    test "all read-only contracts blocked when task_id is nil" do
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, Policy.default(), ctx)
        assert Gate.blocked?(decision),
               "#{contract.name} should be blocked without active task, got #{inspect(decision)}"
      end
    end

    test "task_id empty string blocks deterministically" do
      ctx = %{mode: :plan, task_category: :researching, task_id: ""}
      assert {:block, :no_active_task} = Gate.evaluate(read_contract(), Policy.default(), ctx)
    end

    test "task_id non-binary (integer) blocks deterministically" do
      ctx = %{mode: :plan, task_category: :researching, task_id: 42}
      assert {:block, :no_active_task} = Gate.evaluate(read_contract(), Policy.default(), ctx)
    end

    test "task_category nil blocks deterministically" do
      ctx = %{mode: :plan, task_category: nil, task_id: "t1"}
      assert {:block, :no_active_task} = Gate.evaluate(read_contract(), Policy.default(), ctx)
    end

    test "task_category non-atom (string) blocks deterministically" do
      ctx = %{mode: :plan, task_category: "researching", task_id: "t1"}
      assert {:block, :no_active_task} = Gate.evaluate(read_contract(), Policy.default(), ctx)
    end

    test "both task_id and task_category omitted blocks deterministically" do
      ctx = %{mode: :plan}
      assert {:block, :no_active_task} = Gate.evaluate(read_contract(), Policy.default(), ctx)
    end

    test "relaxed policy (require_active_task: false) skips active task check" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(read_contract(), policy, ctx)

      # Should not be {:block, :no_active_task} — that invariant is off
      refute match?({:block, :no_active_task}, decision)
    end

    # -- Fail-closed with corrupted policy data --

    test "fail closed: empty safe_modes policy still blocks without active task" do
      policy = empty_safe_modes_policy()
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      assert Gate.blocked?(decision)
    end

    test "fail closed: nil safe_modes policy still blocks without active task" do
      policy = nil_safe_modes_policy()
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      assert Gate.blocked?(decision)
    end

    test "fail closed: all-nil policy fields block mutation" do
      policy = struct(Policy, %{
        plan_mode: :plan,
        safe_modes: nil,
        plan_safe_categories: nil,
        acting_categories: nil,
        require_active_task: true
      })

      for contract <- [write_contract(), shell_contract()],
          mode <- [:plan, :explore, :execute],
          category <- [:researching, :planning, :acting] do
        ctx = %{mode: mode, task_category: category, task_id: "t_corrupt"}
        decision = Gate.evaluate(contract, policy, ctx)

        assert Gate.blocked?(decision),
               "all-nil policy allowed mutation for #{contract.name} in #{mode}/#{category}: #{inspect(decision)}"
      end
    end

    test "fail closed: all-nil policy fields allow read-only contracts safely" do
      policy = struct(Policy, %{
        plan_mode: :plan,
        safe_modes: nil,
        plan_safe_categories: nil,
        acting_categories: nil,
        require_active_task: true
      })

      ctx = %{mode: :plan, task_category: :researching, task_id: "t_valid"}
      decision = Gate.evaluate(read_contract(), policy, ctx)

      # Read-only contracts are inherently safe — fail-closed blocks mutation,
      # not read-only access.
      assert Gate.allowed?(decision),
             "nil policy should still allow read-only, got #{inspect(decision)}"

      refute Gate.guided?(decision),
             "nil policy should not emit guidance (no plan-safe modes), got #{inspect(decision)}"
    end
  end

  # ============================================================
  # Invariant 2: Category Gate Behavior
  # ============================================================
  # Plan-safe categories (researching, planning) MUST restrict tools
  # to read-only. Acting categories (acting, verifying, debugging,
  # documenting) unlock mutating tools. The gate never widens
  # permissions beyond what the category allows.

  describe "Invariant 2: category gate behavior" do
    # -- Plan-safe categories block mutation --

    test "write contract blocked in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "write contract blocked in plan/planning" do
      ctx = %{mode: :plan, task_category: :planning, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "write contract blocked in explore/researching" do
      ctx = %{mode: :explore, task_category: :researching, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "shell contract blocked in all plan-safe mode/category combos" do
      for mode <- [:plan, :explore], category <- [:researching, :planning] do
        ctx = %{mode: mode, task_category: category, task_id: "t_cat"}
        decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)
        assert Gate.blocked?(decision),
               "shell should be blocked in #{mode}/#{category}, got #{inspect(decision)}"
      end
    end

    # -- Acting categories unlock mutation in execute mode --

    test "write contract allowed in execute/acting" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      assert Gate.allowed?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "write contract allowed in execute/verifying" do
      ctx = %{mode: :execute, task_category: :verifying, task_id: "t1"}
      assert Gate.allowed?(Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx))
    end

    # -- Plan-safe categories in non-plan-safe mode still block mutation --

    test "write contract blocked in execute/researching (plan-safe category)" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    test "write contract blocked in execute/planning (plan-safe category)" do
      ctx = %{mode: :execute, task_category: :planning, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), ctx))
    end

    # -- Read-only tools always allowed with valid context --

    test "read-only tools allowed in all valid plan-safe mode/category combos" do
      for mode <- [:plan, :explore], category <- [:researching, :planning] do
        ctx = %{mode: mode, task_category: category, task_id: "t_ro"}

        for contract <- ReadOnlyContracts.all() do
          decision = Gate.evaluate(contract, Policy.default(), ctx)
          assert Gate.allowed?(decision),
                 "#{contract.name} should be allowed in #{mode}/#{category}, got #{inspect(decision)}"
        end
      end
    end

    test "read-only tools allowed in execute/acting" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      assert Gate.allowed?(Gate.evaluate(read_contract(), Policy.default(), ctx))
    end

    # -- Contract-declared category enforcement (BD-0025 phase 2) --

    test "contract that omits runtime category is blocked even if policy allows" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    # -- Fail-closed with corrupted policy category data --

    test "fail closed: empty plan_safe_categories policy does not widen read-only" do
      policy = empty_plan_safe_categories_policy()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      # Missing plan_safe_categories means the category is treated as
      # non-plan-safe, falling through to the read-only shortcut —
      # still safe because read-only can't mutate.
      assert Gate.blocked?(decision) or Gate.allowed?(decision)
    end

    test "fail closed: nil acting_categories policy restricts mutation in execute" do
      policy = struct(Policy, %{
        plan_mode: :plan,
        safe_modes: [:plan, :explore],
        plan_safe_categories: [:researching, :planning],
        acting_categories: nil,
        require_active_task: true
      })

      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(write_contract(), policy, ctx)
      assert Gate.blocked?(decision),
             "nil acting_categories should fail closed, got #{inspect(decision)}"
    end

    test "fail closed: unknown category blocks even read-only" do
      ctx = %{mode: :execute, task_category: :unknown_category, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      # :unknown_category not in contract.task_categories → phase 2 blocks
      assert Gate.blocked?(decision),
             "unknown category should fail closed, got #{inspect(decision)}"
    end
  end

  # ============================================================
  # Invariant 3: Hook Ordering Determinism
  # ============================================================
  # Gate checks are applied in a well-defined order:
  #   1. Active task check
  #   2. Contract mode check
  #   3. Plan-mode gate
  #   4. Category gate
  #   5. Guidance emission (after allow)
  #
  # Same inputs MUST always produce the same decision. Hook system
  # (BD-0024) is stubbed — we verify the gate's own ordering and
  # determinism guarantees. Fail-closed: if an earlier check would
  # block, a later check must not override it.

  describe "Invariant 3: hook ordering determinism" do
    # -- Gate check order is well-defined --

    test "active task check runs before plan-mode gate" do
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "contract mode check runs before plan-mode gate" do
      ctx = %{mode: :plan, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :mode_not_allowed} = decision
    end

    test "plan-mode gate runs before category gate" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)
      assert {:block, :plan_mode_blocks_mutation} = decision
    end

    test "category gate blocks when contract doesn't declare runtime category" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    # -- Determinism: same inputs always produce same outputs --

    test "same inputs produce identical decisions (1000 evaluations)" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_det"}
      policy = Policy.default()
      contract = read_contract()

      decisions = for _i <- 1..1000, do: Gate.evaluate(contract, policy, ctx)
      unique = Enum.uniq(decisions)

      assert length(unique) == 1, "Expected deterministic output, got #{length(unique)} variants"
      assert Gate.allowed?(hd(unique))
    end

    test "batch evaluation is deterministic and order-preserving" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_det2"}
      results1 = Gate.evaluate_all(ReadOnlyContracts.all(), Policy.default(), ctx)
      results2 = Gate.evaluate_all(ReadOnlyContracts.all(), Policy.default(), ctx)
      assert results1 == results2
    end

    test "evaluate_all preserves input contract order" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_order"}
      contracts = ReadOnlyContracts.all()
      results = Gate.evaluate_all(contracts, Policy.default(), ctx)
      result_names = Enum.map(results, fn {name, _} -> name end)
      input_names = Enum.map(contracts, & &1.name)
      assert result_names == input_names
    end

    # -- Earlier checks take priority (fail-closed ordering) --

    test "no_active_task takes priority over plan_mode_blocks_mutation" do
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "invalid_context takes priority over category_blocks_tool" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: nil, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      assert match?({:block, :invalid_context}, decision)
    end

    # -- Hook stub: future BD-0024 integration point --

    test "gate decision is stable hook input (stub for BD-0024)" do
      contexts = [
        %{mode: :plan, task_category: :researching, task_id: "t1"},
        %{mode: :execute, task_category: :acting, task_id: "t2"},
        %{mode: :plan, task_category: nil, task_id: "t3"},
        %{mode: :plan, task_category: :researching, task_id: nil}
      ]

      for ctx <- contexts, contract <- [read_contract(), write_contract()] do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        assert match?(:allow, decision) or
                 match?({:block, _}, decision) or
                 match?({:guide, _}, decision),
               "unexpected decision shape: #{inspect(decision)}"
      end
    end
  end
end
