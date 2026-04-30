defmodule Tet.PlanMode.GateTest do
  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Tool.Contract
  alias Tet.Tool.ReadOnlyContracts

  # -- Helpers --

  defp read_contract do
    {:ok, c} = ReadOnlyContracts.fetch("read")
    c
  end

  defp list_contract do
    {:ok, c} = ReadOnlyContracts.fetch("list")
    c
  end

  defp search_contract do
    {:ok, c} = ReadOnlyContracts.fetch("search")
    c
  end

  defp ask_user_contract do
    {:ok, c} = ReadOnlyContracts.fetch("ask-user")
    c
  end

  defp plan_research_ctx do
    %{mode: :plan, task_category: :researching, task_id: "t1"}
  end

  defp plan_planning_ctx do
    %{mode: :plan, task_category: :planning, task_id: "t2"}
  end

  defp execute_acting_ctx do
    %{mode: :execute, task_category: :acting, task_id: "t3"}
  end

  defp explore_research_ctx do
    %{mode: :explore, task_category: :researching, task_id: "t4"}
  end

  # Build a simulated mutating write contract for testing block paths.
  # We reuse the struct shape from a read-only contract and override the
  # fields that make it mutating. The gate only reads these fields, so
  # this is safe for pure-function testing.
  defp write_contract do
    %Contract{} = base = read_contract()

    %{
      base
      | name: "write-file",
        read_only: false,
        mutation: :write,
        modes: [:execute, :repair],
        task_categories: [:acting, :verifying, :debugging],
        execution: %{
          base.execution
          | mutates_workspace: true,
            executes_code: false,
            status: :contract_only,
            effects: [:writes_file]
        }
    }
  end

  defp shell_contract do
    %Contract{} = base = read_contract()

    %{
      base
      | name: "shell",
        read_only: false,
        mutation: :execute,
        modes: [:execute],
        task_categories: [:acting, :debugging],
        execution: %{
          base.execution
          | executes_code: true,
            mutates_workspace: true,
            status: :contract_only,
            effects: [:executes_shell_command]
        }
    }
  end

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
      # write_contract declares [:execute, :repair], not :plan
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
      ctx = %{mode: :plan, task_category: nil, task_id: nil}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      assert Gate.allowed?(decision)
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

  # -- Mutating tool invariant: planning cannot mutate --

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
  end
end
