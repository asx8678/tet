defmodule Tet.PlanMode.GateTest do
  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Tool.ReadOnlyContracts

  import Tet.PlanMode.GateTestHelpers

  # -- Gate decisions for read-only tools in plan mode --

  describe "read-only tools in plan mode" do
    test "read contract is allowed with guidance in plan/researching context" do
      decision = Gate.evaluate(read_contract(), Policy.default(), plan_research_ctx())
      assert Gate.guided?(decision)
      assert {:guide, msg} = decision
      assert msg =~ "Plan-mode research allowed"
      assert Gate.allowed?(decision)
    end

    test "list contract is allowed with guidance in plan/planning context" do
      decision = Gate.evaluate(list_contract(), Policy.default(), plan_planning_ctx())
      assert Gate.allowed?(decision)
      assert Gate.guided?(decision)
    end

    test "search contract is allowed with guidance in plan/researching context" do
      decision = Gate.evaluate(search_contract(), Policy.default(), plan_research_ctx())
      assert Gate.allowed?(decision)
      assert Gate.guided?(decision)
    end

    test "ask-user contract is allowed with guidance in plan/researching context" do
      decision = Gate.evaluate(ask_user_contract(), Policy.default(), plan_research_ctx())
      assert Gate.allowed?(decision)
      assert Gate.guided?(decision)
    end

    test "all BD-0020 read-only contracts are allowed in plan mode with researching task" do
      results =
        Gate.evaluate_all(
          ReadOnlyContracts.all(),
          Policy.default(),
          plan_research_ctx()
        )

      for {name, decision} <- results do
        assert Gate.allowed?(decision),
               "expected #{name} to be allowed in plan/researching, got #{inspect(decision)}"
      end

      assert length(results) == 6
    end
  end

  describe "read-only tools in explore mode" do
    test "read contract is allowed with guidance in explore/researching context" do
      decision = Gate.evaluate(read_contract(), Policy.default(), explore_research_ctx())
      assert Gate.allowed?(decision)
      assert Gate.guided?(decision)
    end

    test "all BD-0020 read-only contracts are allowed in explore mode" do
      results =
        Gate.evaluate_all(
          ReadOnlyContracts.all(),
          Policy.default(),
          explore_research_ctx()
        )

      for {name, decision} <- results do
        assert Gate.allowed?(decision),
               "expected #{name} to be allowed in explore/researching, got #{inspect(decision)}"
      end
    end
  end

  describe "read-only tools in execute mode" do
    test "read contract is allowed (no guidance) in execute/acting context" do
      decision = Gate.evaluate(read_contract(), Policy.default(), execute_acting_ctx())
      assert decision == :allow
      assert Gate.allowed?(decision)
      refute Gate.guided?(decision)
    end

    test "all BD-0020 read-only contracts are allowed in execute/acting" do
      results =
        Gate.evaluate_all(
          ReadOnlyContracts.all(),
          Policy.default(),
          execute_acting_ctx()
        )

      for {name, decision} <- results do
        assert Gate.allowed?(decision),
               "expected #{name} to be allowed in execute/acting, got #{inspect(decision)}"
      end
    end
  end

  # -- Mutating tools blocked in plan mode --

  describe "mutating tools in plan mode" do
    test "write-file contract is blocked in plan/researching context" do
      decision = Gate.evaluate(write_contract(), Policy.default(), plan_research_ctx())
      assert Gate.blocked?(decision)
    end

    test "write-file contract is blocked in plan/planning context" do
      decision = Gate.evaluate(write_contract(), Policy.default(), plan_planning_ctx())
      assert Gate.blocked?(decision)
    end

    test "shell contract is blocked in plan/researching context" do
      decision = Gate.evaluate(shell_contract(), Policy.default(), plan_research_ctx())
      assert Gate.blocked?(decision)
    end

    test "mutating contract without plan mode declaration is blocked" do
      decision = Gate.evaluate(write_contract(), Policy.default(), plan_research_ctx())
      assert Gate.blocked?(decision)
      assert match?({:block, _}, decision)
    end
  end

  # -- Mutating tools allowed in execute/acting mode --

  describe "mutating tools in execute mode" do
    test "write-file contract is allowed in execute/acting context" do
      decision = Gate.evaluate(write_contract(), Policy.default(), execute_acting_ctx())
      assert Gate.allowed?(decision)
      assert decision == :allow
    end

    test "shell contract is allowed in execute/acting context" do
      decision = Gate.evaluate(shell_contract(), Policy.default(), execute_acting_ctx())
      assert Gate.allowed?(decision)
    end
  end

  # -- No active task invariant --

  describe "no active task invariant" do
    test "blocks when task_id is nil and policy requires active task" do
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "blocks when task_category is nil and policy requires active task" do
      ctx = %{mode: :plan, task_category: nil, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "allows when require_active_task is false" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      assert Gate.allowed?(decision)
    end

    # -- fail-closed regressions --

    test "blocks when task_id is omitted from context" do
      ctx = %{mode: :plan, task_category: :researching}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "blocks when task_category is omitted from context" do
      ctx = %{mode: :plan, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "blocks when task_id is empty string" do
      ctx = %{mode: :plan, task_category: :researching, task_id: ""}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "blocks when task_id is non-binary (atom)" do
      ctx = %{mode: :plan, task_category: :researching, task_id: :atom_id}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "blocks mutating contract when task_id is nil" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "blocks shell/executing contract when task_id is nil" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "blocks acting-context contract when task_id is nil" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    test "blocks when both task_id and task_category are omitted" do
      ctx = %{mode: :plan}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end
  end

  # -- Category gating --

  describe "category-based tool gating" do
    test "acting category in plan mode still allows read-only tools" do
      ctx = %{mode: :plan, task_category: :acting, task_id: "t5"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "acting category in plan mode still blocks mutating tools" do
      ctx = %{mode: :plan, task_category: :acting, task_id: "t5"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert Gate.blocked?(decision)
    end

    test "researching category in execute mode blocks mutating tools" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t6"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert Gate.blocked?(decision)
      assert {:block, :category_blocks_tool} = decision
    end

    test "planning category in execute mode blocks mutating tools" do
      ctx = %{mode: :execute, task_category: :planning, task_id: "t7"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert Gate.blocked?(decision)
    end

    test "researching category in execute mode allows read-only tools" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t6"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    # -- contract-declared task_categories enforced --

    test "contract with mismatched task_categories blocked in execute/acting" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t8"}
      decision = Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx)
      assert Gate.blocked?(decision)
      assert {:block, :category_blocks_tool} = decision
    end

    test "contract with matching task_categories allowed in execute/acting" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t3"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "contract with matching task_categories allowed in execute/verifying" do
      ctx = %{mode: :execute, task_category: :verifying, task_id: "t9"}
      decision = Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "runtime category mismatched with declared categories blocks even if policy allows" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t10"}
      decision = Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx)
      assert Gate.blocked?(decision)
    end

    test "read-only contract with any category passes contract_allows_category check" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t11"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end
  end

  # -- QA-1: read-only contract must declare runtime category (contract_allows_category? prerequisite) --

  describe "QA-1: contract_allows_category? prerequisite for read-only contracts" do
    test "read-only contract that omits runtime category is blocked in plan/researching" do
      # read_only_planning_only_contract declares only [:planning], omits :researching
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_qa1a"}
      decision = Gate.evaluate(read_only_planning_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "read-only contract that omits runtime category is blocked in execute/acting" do
      # read_only_planning_only_contract declares only [:planning], omits :acting
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_qa1b"}
      decision = Gate.evaluate(read_only_planning_only_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "read-only contract that declares runtime category is allowed in plan/planning" do
      # read_only_planning_only_contract declares [:planning] — matching
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
      # write_verifying_only_contract declares only [:verifying], but context is :acting
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_qa1e"}
      decision = Gate.evaluate(write_verifying_only_contract(), Policy.default(), ctx)
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

  # -- Decision helpers --

  describe "decision helpers" do
    test "allowed? returns true for :allow and {:guide, _}" do
      assert Gate.allowed?(:allow) == true
      assert Gate.allowed?({:guide, "hint"}) == true
      assert Gate.allowed?({:block, :reason}) == false
    end

    test "blocked? returns true only for {:block, _}" do
      assert Gate.blocked?({:block, :reason}) == true
      assert Gate.blocked?(:allow) == false
      assert Gate.blocked?({:guide, "hint"}) == false
    end

    test "guided? returns true only for {:guide, _}" do
      assert Gate.guided?({:guide, "hint"}) == true
      assert Gate.guided?(:allow) == false
      assert Gate.guided?({:block, :reason}) == false
    end
  end

  # -- Contract builder normalizes atom-vs-string metadata --

  describe "Contract builder normalizes atom-vs-string metadata" do
    test "contract built with string modes via builder is normalized to atoms" do
      contract = string_metadata_contract()
      assert :plan in contract.modes
      assert :explore in contract.modes
      assert :execute in contract.modes
    end

    test "contract built with string task_categories via builder is normalized to atoms" do
      contract = string_metadata_contract()
      assert :researching in contract.task_categories
      assert :planning in contract.task_categories
      assert :acting in contract.task_categories
    end

    test "string-normalized contract works correctly in gate evaluation" do
      contract = string_metadata_contract()
      decision = Gate.evaluate(contract, Policy.default(), plan_research_ctx())
      assert Gate.allowed?(decision)
    end

    test "string-normalized contract passes contract mode check" do
      contract = string_metadata_contract()
      decision = Gate.evaluate(contract, Policy.default(), plan_research_ctx())
      assert Gate.guided?(decision) or decision == :allow
    end
  end

  # -- Full catalog sweep --

  describe "full catalog evaluation" do
    test "all read-only contracts allowed in every plan-safe mode with plan-safe category" do
      for mode <- [:plan, :explore], category <- [:researching, :planning] do
        ctx = %{mode: mode, task_category: category, task_id: "t_sweep"}
        results = Gate.evaluate_all(ReadOnlyContracts.all(), Policy.default(), ctx)

        for {name, decision} <- results do
          assert Gate.allowed?(decision),
                 "#{name} should be allowed in #{mode}/#{category}, got #{inspect(decision)}"
        end
      end
    end

    test "no read-only contract is blocked in any valid plan context" do
      for mode <- Policy.safe_modes(),
          category <- Policy.plan_safe_categories() ++ Policy.acting_categories() do
        ctx = %{mode: mode, task_category: category, task_id: "t_all"}
        results = Gate.evaluate_all(ReadOnlyContracts.all(), Policy.default(), ctx)

        for {name, decision} <- results do
          assert Gate.allowed?(decision),
                 "#{name} blocked in #{mode}/#{category}: #{inspect(decision)}"
        end
      end
    end
  end

  # -- BD-0025 acceptance: planning cannot mutate --

  describe "BD-0025 acceptance: planning cannot mutate or execute non-read tools" do
    test "write tool is blocked in all plan-safe modes with all plan-safe categories" do
      for mode <- [:plan, :explore], category <- [:researching, :planning] do
        ctx = %{mode: mode, task_category: category, task_id: "t_inv"}
        decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

        assert Gate.blocked?(decision),
               "write should be blocked in #{mode}/#{category}, got #{inspect(decision)}"
      end
    end

    test "shell tool is blocked in all plan-safe modes with all plan-safe categories" do
      for mode <- [:plan, :explore], category <- [:researching, :planning] do
        ctx = %{mode: mode, task_category: category, task_id: "t_inv"}
        decision = Gate.evaluate(shell_contract(), Policy.default(), ctx)

        assert Gate.blocked?(decision),
               "shell should be blocked in #{mode}/#{category}, got #{inspect(decision)}"
      end
    end

    test "write tool is allowed once task commits to acting in execute mode" do
      decision = Gate.evaluate(write_contract(), Policy.default(), execute_acting_ctx())
      assert Gate.allowed?(decision)
    end

    test "no active task blocks even read-only tools by default" do
      ctx = %{mode: :plan, task_category: nil, task_id: nil}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision
    end

    # -- plan mode blocks rogue mutating contracts --

    test "mutating contract that incorrectly declares :plan mode is blocked" do
      decision =
        Gate.evaluate(
          rogue_plan_write_contract(),
          Policy.default(),
          plan_research_ctx()
        )

      assert {:block, :plan_mode_blocks_mutation} = decision
    end

    test "shell/executing contract that incorrectly declares :plan mode is blocked" do
      decision =
        Gate.evaluate(
          rogue_plan_shell_contract(),
          Policy.default(),
          plan_research_ctx()
        )

      assert {:block, :plan_mode_blocks_mutation} = decision
    end

    test "rogue mutating contract blocked in all plan-safe modes" do
      for mode <- [:plan, :explore], category <- [:researching, :planning] do
        ctx = %{mode: mode, task_category: category, task_id: "t_rogue"}

        decision =
          Gate.evaluate(
            rogue_plan_write_contract(),
            Policy.default(),
            ctx
          )

        assert {:block, :plan_mode_blocks_mutation} = decision,
               "rogue-plan-write should be blocked in #{mode}/#{category}"
      end
    end
  end

  # -- Facade coverage for invalid context --

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
  end
end
