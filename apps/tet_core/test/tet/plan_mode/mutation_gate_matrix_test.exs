defmodule Tet.PlanMode.MutationGateMatrixTest do
  @moduledoc """
  BD-0030: Mutation gate audit tests — full gate matrix.

  Verifies that:
    7. The full mutation gate matrix: task × category × mode × tool

  Every combination of task state, task category, runtime mode, and
  tool contract produces the expected deterministic gate decision,
  and every decision is persistable as an auditable event.

  ## Matrix dimensions

  - **Task state**: active (valid task_id + task_category), missing task_id,
    missing task_category, empty task_id, nil task_category
  - **Category**: :researching, :planning, :acting, :verifying, :debugging
  - **Mode**: :plan, :explore, :execute, :repair
  - **Tool**: read-only (read), mutating-write (write-file), mutating-shell (shell)

  ## Decision legend

  - `:allow` — tool call may proceed
  - `{:guide, _}` — allowed with guidance hint (read-only in plan mode)
  - `{:block, reason}` — denied (reason is a stable atom)
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}

  import Tet.PlanMode.GateTestHelpers
  import Tet.PlanMode.MutationGateAuditTestHelpers

  @policy Policy.default()

  # ============================================================
  # Read-only tool matrix (read contract)
  # ============================================================

  describe "matrix: read-only tool (read contract) — always allowed with active task" do
    test "read allowed in every mode × category combination with active task" do
      modes = [:plan, :explore, :execute, :repair]
      categories = [:researching, :planning, :acting, :verifying, :debugging]

      for mode <- modes, category <- categories do
        ctx = %{mode: mode, task_category: category, task_id: "t_matrix_ro"}
        decision = Gate.evaluate(read_contract(), @policy, ctx)

        # Read-only contracts are always allowed or guided (never blocked)
        assert Gate.allowed?(decision),
               "read in #{mode}/#{category} should be allowed, got #{inspect(decision)}"

        assert {:ok, _event} = persist_decision(read_contract(), decision),
               "Failed to persist read in #{mode}/#{category}"
      end
    end

    test "read in plan mode + plan-safe category produces guide" do
      for category <- [:researching, :planning] do
        ctx = %{mode: :plan, task_category: category, task_id: "t_guide"}
        decision = Gate.evaluate(read_contract(), @policy, ctx)

        assert {:guide, _msg} = decision,
               "read in plan/#{category} should be guided, got #{inspect(decision)}"
      end
    end

    test "read in non-plan mode or non-plan-safe category produces plain allow" do
      combos = [
        {%{mode: :explore, task_category: :acting, task_id: "t1"}},
        {%{mode: :execute, task_category: :acting, task_id: "t2"}},
        {%{mode: :repair, task_category: :researching, task_id: "t3"}},
        {%{mode: :plan, task_category: :acting, task_id: "t4"}}
      ]

      for {ctx} <- combos do
        decision = Gate.evaluate(read_contract(), @policy, ctx)
        assert decision == :allow, "read in #{ctx.mode}/#{ctx.task_category} should be :allow"
      end
    end

    test "read blocked without active task" do
      for task_id <- [nil, ""],
          category <- [:acting, :researching] do
        ctx = %{mode: :execute, task_category: category, task_id: task_id}
        decision = Gate.evaluate(read_contract(), @policy, ctx)
        assert {:block, :no_active_task} = decision

        assert {:ok, _event} = persist_decision(read_contract(), decision)
      end
    end

    test "read blocked with nil task_category" do
      ctx = %{mode: :execute, task_category: nil, task_id: "t_valid"}
      decision = Gate.evaluate(read_contract(), @policy, ctx)
      assert {:block, :no_active_task} = decision
    end
  end

  # ============================================================
  # Write tool matrix (write-file contract)
  # ============================================================

  describe "matrix: mutating write tool (write-file contract)" do
    test "write allowed only in execute/repair × acting/verifying/debugging" do
      # Expected allowed combos for write_contract
      allowed_combos = [
        {:execute, :acting},
        {:execute, :verifying},
        {:execute, :debugging},
        {:repair, :acting},
        {:repair, :verifying},
        {:repair, :debugging}
      ]

      for {mode, category} <- allowed_combos do
        ctx = %{mode: mode, task_category: category, task_id: "t_write_allow"}
        decision = Gate.evaluate(write_contract(), @policy, ctx)

        assert decision == :allow,
               "write in #{mode}/#{category} should be :allow, got #{inspect(decision)}"

        assert {:ok, event} = persist_decision(write_contract(), decision)
        assert event.type == :"tool.started"
      end
    end

    test "write blocked in plan/explore modes (mode not allowed)" do
      modes_to_check = [:plan, :explore]

      for mode <- modes_to_check,
          category <- [:acting, :verifying, :researching, :planning] do
        ctx = %{mode: mode, task_category: category, task_id: "t_write_mode"}
        decision = Gate.evaluate(write_contract(), @policy, ctx)

        assert {:block, :mode_not_allowed} = decision,
               "write in #{mode}/#{category} should be blocked by mode, got #{inspect(decision)}"
      end
    end

    test "write blocked in execute with plan-safe categories" do
      plan_safe_cats = [:researching, :planning]

      for category <- plan_safe_cats do
        ctx = %{mode: :execute, task_category: category, task_id: "t_write_cat"}
        decision = Gate.evaluate(write_contract(), @policy, ctx)

        assert {:block, :category_blocks_tool} = decision,
               "write in execute/#{category} should be blocked, got #{inspect(decision)}"
      end
    end

    test "write blocked without active task in every mode × category" do
      modes = [:plan, :explore, :execute, :repair]
      categories = [:researching, :planning, :acting, :verifying]

      for mode <- modes, category <- categories do
        ctx = %{mode: mode, task_category: category, task_id: nil}
        decision = Gate.evaluate(write_contract(), @policy, ctx)
        assert Gate.blocked?(decision)

        assert {:ok, _event} = persist_decision(write_contract(), decision),
               "Failed to persist write-no-task in #{mode}/#{category}"
      end
    end

    test "write blocked with non-binary task_id" do
      ctx = %{mode: :execute, task_category: :acting, task_id: 42}
      decision = Gate.evaluate(write_contract(), @policy, ctx)
      assert {:block, :no_active_task} = decision
    end

    test "write blocked with string task_category" do
      ctx = %{mode: :execute, task_category: "acting", task_id: "t_valid"}
      decision = Gate.evaluate(write_contract(), @policy, ctx)
      assert {:block, :no_active_task} = decision
    end
  end

  # ============================================================
  # Shell tool matrix (shell contract)
  # ============================================================

  describe "matrix: mutating shell tool" do
    test "shell allowed in execute × acting and execute × debugging" do
      allowed_combos = [{:execute, :acting}, {:execute, :debugging}]

      for {mode, category} <- allowed_combos do
        ctx = %{mode: mode, task_category: category, task_id: "t_shell_allow"}
        decision = Gate.evaluate(shell_contract(), @policy, ctx)

        assert decision == :allow,
               "shell in #{mode}/#{category} should be :allow, got #{inspect(decision)}"

        assert {:ok, event} = persist_decision(shell_contract(), decision)
        assert event.type == :"tool.started"
      end
    end

    test "shell blocked in execute × verifying (not declared)" do
      ctx = %{mode: :execute, task_category: :verifying, task_id: "t_shell_ver"}
      decision = Gate.evaluate(shell_contract(), @policy, ctx)

      assert {:block, :category_blocks_tool} = decision
    end

    test "shell blocked in all non-execute modes" do
      non_execute_modes = [:plan, :explore, :repair]

      for mode <- non_execute_modes,
          category <- [:acting, :verifying, :researching, :planning] do
        ctx = %{mode: mode, task_category: category, task_id: "t_shell_mode"}
        decision = Gate.evaluate(shell_contract(), @policy, ctx)

        assert {:block, :mode_not_allowed} = decision,
               "shell in #{mode}/#{category} should be blocked by mode, got #{inspect(decision)}"
      end
    end

    test "shell blocked in execute × plan-safe categories" do
      plan_safe_cats = [:researching, :planning]

      for category <- plan_safe_cats do
        ctx = %{mode: :execute, task_category: category, task_id: "t_shell_cat"}
        decision = Gate.evaluate(shell_contract(), @policy, ctx)

        assert {:block, :category_blocks_tool} = decision
      end
    end

    test "shell blocked without active task" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      decision = Gate.evaluate(shell_contract(), @policy, ctx)
      assert {:block, :no_active_task} = decision
    end
  end

  # ============================================================
  # Rogue contract matrix (mutations that declare plan mode)
  # ============================================================

  describe "matrix: rogue write contract (declares plan/explore modes)" do
    test "rogue write blocked in plan mode by plan_mode_blocks_mutation" do
      for category <- [:acting, :verifying, :researching, :planning] do
        ctx = %{mode: :plan, task_category: category, task_id: "t_rogue_plan"}
        decision = Gate.evaluate(rogue_plan_write_contract(), @policy, ctx)

        assert {:block, :plan_mode_blocks_mutation} = decision,
               "rogue-write in plan/#{category} should be blocked, got #{inspect(decision)}"
      end
    end

    test "rogue write blocked in explore mode by plan_mode_blocks_mutation" do
      for category <- [:acting, :verifying, :researching, :planning] do
        ctx = %{mode: :explore, task_category: category, task_id: "t_rogue_exp"}
        decision = Gate.evaluate(rogue_plan_write_contract(), @policy, ctx)

        assert {:block, :plan_mode_blocks_mutation} = decision,
               "rogue-write in explore/#{category} should be blocked, got #{inspect(decision)}"
      end
    end

    test "rogue write allowed in execute mode with acting category" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_rogue_exec"}
      decision = Gate.evaluate(rogue_plan_write_contract(), @policy, ctx)
      assert decision == :allow
    end

    test "rogue write blocked in execute with plan-safe category" do
      for category <- [:researching, :planning] do
        ctx = %{mode: :execute, task_category: category, task_id: "t_rogue_ps"}
        decision = Gate.evaluate(rogue_plan_write_contract(), @policy, ctx)

        assert {:block, :category_blocks_tool} = decision
      end
    end

    test "rogue write blocked in repair (not declared) for plan categories" do
      for category <- [:acting, :researching] do
        ctx = %{mode: :repair, task_category: category, task_id: "t_rogue_repair"}
        decision = Gate.evaluate(rogue_plan_write_contract(), @policy, ctx)

        assert Gate.blocked?(decision),
               "rogue-write in repair/#{category} should be blocked"
      end
    end

    test "rogue write blocked without active task even in declared modes" do
      modes = [:plan, :explore, :execute]

      for mode <- modes do
        ctx = %{mode: mode, task_category: :acting, task_id: nil}
        decision = Gate.evaluate(rogue_plan_write_contract(), @policy, ctx)
        assert {:block, :no_active_task} = decision
      end
    end
  end

  # ============================================================
  # Full matrix: exhaustive sweep with persistence
  # ============================================================

  describe "full matrix: exhaustive sweep — every decision is deterministically correct and persistable" do
    test "all contracts × all contexts produce expected decision shapes" do
      contracts = [
        {read_contract(), :read_only},
        {write_contract(), :mutating_write},
        {shell_contract(), :mutating_shell}
      ]

      modes = [:plan, :explore, :execute, :repair]
      categories = [:researching, :planning, :acting, :verifying, :debugging]

      for {contract, contract_type} <- contracts,
          mode <- modes,
          category <- categories do
        ctx = %{mode: mode, task_category: category, task_id: "t_exhaustive"}

        decision = Gate.evaluate(contract, @policy, ctx)

        # Every decision is either :allow, {:guide, _}, or {:block, _}
        valid_shape? =
          decision == :allow or
            match?({:guide, _}, decision) or
            match?({:block, _}, decision)

        assert valid_shape?,
               "#{contract_type}(#{contract.name}) in #{mode}/#{category}: invalid shape #{inspect(decision)}"

        # Every decision is persistable as an event
        assert {:ok, _event} =
                 persist_decision(contract, decision),
               "#{contract_type}(#{contract.name}) in #{mode}/#{category}: failed to persist #{inspect(decision)}"
      end
    end

    test "all mutating contracts blocked in every mode × category without task" do
      mutating_contracts = [write_contract(), shell_contract()]
      modes = [:plan, :explore, :execute, :repair]
      categories = [:researching, :planning, :acting, :verifying, :debugging]

      for contract <- mutating_contracts,
          mode <- modes,
          category <- categories do
        ctx = %{mode: mode, task_category: category, task_id: nil}
        decision = Gate.evaluate(contract, @policy, ctx)

        assert {:block, :no_active_task} = decision,
               "#{contract.name} in #{mode}/#{category} without task should be blocked, got #{inspect(decision)}"
      end
    end

    test "read-only contracts allowed (or guided) in every valid context" do
      modes = [:plan, :explore, :execute, :repair]
      categories = [:researching, :planning, :acting, :verifying, :debugging]

      for mode <- modes, category <- categories do
        ctx = %{mode: mode, task_category: category, task_id: "t_ro_sweep"}
        decision = Gate.evaluate(read_contract(), @policy, ctx)

        assert Gate.allowed?(decision),
               "read in #{mode}/#{category} should be allowed, got #{inspect(decision)}"
      end
    end
  end

  # ============================================================
  # Full matrix with no task — universal block
  # ============================================================

  describe "full matrix: no active task blocks all mutating tools in all contexts" do
    test "write and shell contracts blocked with nil task_id" do
      contracts = [write_contract(), shell_contract()]
      modes = [:plan, :explore, :execute, :repair]
      categories = [:researching, :planning, :acting, :verifying]

      for contract <- contracts, mode <- modes, category <- categories do
        ctx = %{mode: mode, task_category: category, task_id: nil}
        decision = Gate.evaluate(contract, @policy, ctx)

        assert {:block, :no_active_task} = decision,
               "#{contract.name} in #{mode}/#{category} nil task_id: expected no_active_task, got #{inspect(decision)}"
      end
    end

    test "write and shell contracts blocked with empty task_id" do
      contracts = [write_contract(), shell_contract()]
      modes = [:plan, :explore, :execute, :repair]
      categories = [:researching, :planning, :acting, :verifying]

      for contract <- contracts, mode <- modes, category <- categories do
        ctx = %{mode: mode, task_category: category, task_id: ""}
        decision = Gate.evaluate(contract, @policy, ctx)

        assert {:block, :no_active_task} = decision,
               "#{contract.name} in #{mode}/#{category} empty task_id: expected no_active_task, got #{inspect(decision)}"
      end
    end

    test "write and shell contracts blocked with nil task_category" do
      contracts = [write_contract(), shell_contract()]
      modes = [:plan, :explore, :execute, :repair]

      for contract <- contracts, mode <- modes do
        ctx = %{mode: mode, task_category: nil, task_id: "t_valid"}
        decision = Gate.evaluate(contract, @policy, ctx)

        assert {:block, :no_active_task} = decision,
               "#{contract.name} in #{mode} nil category: expected no_active_task, got #{inspect(decision)}"
      end
    end
  end

  # ============================================================
  # Matrix: verifying-only write contract edge
  # ============================================================

  describe "matrix: verifying-only write contract — category mismatch" do
    test "verifying-only write allowed only in verifying context" do
      ctx = %{mode: :execute, task_category: :verifying, task_id: "t_vo_allow"}
      decision = Gate.evaluate(verifying_only_write_contract(), @policy, ctx)
      assert decision == :allow
    end

    test "verifying-only write blocked in acting context" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_vo_block"}
      decision = Gate.evaluate(verifying_only_write_contract(), @policy, ctx)
      assert {:block, :category_blocks_tool} = decision
    end

    test "verifying-only write blocked in researching/planning contexts" do
      for category <- [:researching, :planning] do
        ctx = %{mode: :execute, task_category: category, task_id: "t_vo_ps"}
        decision = Gate.evaluate(verifying_only_write_contract(), @policy, ctx)
        assert {:block, :category_blocks_tool} = decision
      end
    end
  end

  # ============================================================
  # Matrix summary: count expected allow vs block ratios
  # ============================================================

  describe "matrix summary: allow/block ratios per tool type" do
    test "read-only has 100% allow rate (with active task)" do
      modes = [:plan, :explore, :execute, :repair]
      categories = [:researching, :planning, :acting, :verifying, :debugging]

      results =
        for mode <- modes, category <- categories do
          ctx = %{mode: mode, task_category: category, task_id: "t_ratio_ro"}
          Gate.evaluate(read_contract(), @policy, ctx)
        end

      allowed = Enum.count(results, &Gate.allowed?/1)
      total = length(results)

      assert allowed == total,
             "read-only should have 100% allow rate, got #{allowed}/#{total}"
    end

    test "write contract has limited allow surface — only execute/repair × acting/verifying/debugging" do
      modes = [:plan, :explore, :execute, :repair]
      categories = [:researching, :planning, :acting, :verifying, :debugging]

      results =
        for mode <- modes, category <- categories do
          ctx = %{mode: mode, task_category: category, task_id: "t_ratio_write"}
          {mode, category, Gate.evaluate(write_contract(), @policy, ctx)}
        end

      allowed =
        Enum.filter(results, fn {_, _, d} -> Gate.allowed?(d) end)

      allowed_combos = Enum.map(allowed, fn {m, c, _} -> {m, c} end) |> Enum.sort()

      expected_allowed =
        [
          {:execute, :acting},
          {:execute, :debugging},
          {:execute, :verifying},
          {:repair, :acting},
          {:repair, :debugging},
          {:repair, :verifying}
        ]

      assert allowed_combos == expected_allowed,
             "write allowed combos mismatch: #{inspect(allowed_combos)} != #{inspect(expected_allowed)}"
    end

    test "shell contract has narrowest allow surface — only execute × acting/debugging" do
      modes = [:plan, :explore, :execute, :repair]
      categories = [:researching, :planning, :acting, :verifying, :debugging]

      results =
        for mode <- modes, category <- categories do
          ctx = %{mode: mode, task_category: category, task_id: "t_ratio_shell"}
          {mode, category, Gate.evaluate(shell_contract(), @policy, ctx)}
        end

      allowed =
        Enum.filter(results, fn {_, _, d} -> Gate.allowed?(d) end)

      allowed_combos = Enum.map(allowed, fn {m, c, _} -> {m, c} end) |> Enum.sort()

      expected_allowed = [{:execute, :acting}, {:execute, :debugging}]

      assert allowed_combos == expected_allowed,
             "shell allowed combos mismatch: #{inspect(allowed_combos)} != #{inspect(expected_allowed)}"
    end
  end
end
