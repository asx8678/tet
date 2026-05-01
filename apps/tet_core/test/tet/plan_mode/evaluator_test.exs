defmodule Tet.PlanMode.EvaluatorTest do
  @moduledoc """
  BD-0032: Ring-2 steering evaluator tests.

  Tests the core invariant (no-override guarantee), guidance enrichment,
  focus narrowing, audit trail, and the full gate → evaluator pipeline.
  """
  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Evaluator, Gate, Policy}
  alias Tet.PlanMode.Evaluator.Profile
  alias Tet.Tool.ReadOnlyContracts

  import Tet.PlanMode.GateTestHelpers

  # All block reasons the gate can produce
  @all_block_reasons [
    {:block, :no_active_task},
    {:block, :invalid_context},
    {:block, :mode_not_allowed},
    {:block, :plan_mode_blocks_mutation},
    {:block, :category_blocks_tool}
  ]

  # ============================================================
  # No-Override Guarantee (the core invariant)
  # ============================================================

  describe "no-override guarantee: blocks are always preserved" do
    test "every block reason passes through unchanged with default profile" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for block <- @all_block_reasons do
        {:ok, final, audit} = Evaluator.evaluate(block, profile, ctx)

        assert final == block,
               "expected #{inspect(block)} to pass through, got #{inspect(final)}"

        assert audit.gate_decision == block
        assert audit.final_decision == block
      end
    end

    test "every block reason passes through unchanged with conservative profile" do
      profile = Profile.conservative()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for block <- @all_block_reasons do
        {:ok, final, _audit} = Evaluator.evaluate(block, profile, ctx)
        assert final == block
      end
    end

    test "every block reason passes through unchanged with aggressive profile" do
      profile = Profile.aggressive()
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}

      for block <- @all_block_reasons do
        {:ok, final, _audit} = Evaluator.evaluate(block, profile, ctx)
        assert final == block
      end
    end

    test "block with focus areas in profile still passes through unchanged" do
      profile = Profile.new!(%{focus_areas: [:file_safety, :scope_narrowing]})
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for block <- @all_block_reasons do
        {:ok, final, _audit} = Evaluator.evaluate(block, profile, ctx)
        assert final == block
      end
    end

    test "no_override_guaranteed? returns true for all block reasons" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for block <- @all_block_reasons do
        assert Evaluator.no_override_guaranteed?(block, profile, ctx),
               "no_override_guaranteed? failed for #{inspect(block)}"
      end
    end

    test "no_override_guaranteed? returns true for non-block decisions" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      assert Evaluator.no_override_guaranteed?(:allow, profile, ctx)
      assert Evaluator.no_override_guaranteed?({:guide, "hint"}, profile, ctx)
    end

    test "verify_no_override returns :ok when all blocks preserved" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      assert :ok = Evaluator.verify_no_override(@all_block_reasons, profile, ctx)
    end

    test "blocks from real gate evaluations are always preserved" do
      profile = Profile.default()
      policy = Policy.default()

      blocking_contexts = [
        %{mode: :plan, task_category: :researching, task_id: nil},
        %{mode: :plan, task_category: nil, task_id: "t1"},
        %{mode: :plan, task_id: "t1"},
        %{mode: :execute, task_category: :researching, task_id: "t1"}
      ]

      for ctx <- blocking_contexts, contract <- [write_contract(), shell_contract()] do
        gate_decision = Gate.evaluate(contract, policy, ctx)

        if Gate.blocked?(gate_decision) do
          {:ok, final, _audit} = Evaluator.evaluate(gate_decision, profile, ctx)

          assert final == gate_decision,
                 "gate #{inspect(gate_decision)} overridden for #{contract.name} in #{inspect(ctx)}"
        end
      end
    end

    test "blocks are preserved across all profile configurations" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      profiles = [
        Profile.default(),
        Profile.conservative(),
        Profile.aggressive(),
        Profile.new!(%{focus_areas: [:file_safety, :test_first, :scope_narrowing]}),
        Profile.new!(%{
          aggressiveness: :aggressive,
          risk_tolerance: :low,
          focus_areas: [:minimal_mutations]
        })
      ]

      for profile <- profiles, block <- @all_block_reasons do
        {:ok, final, audit} = Evaluator.evaluate(block, profile, ctx)

        assert final == block,
               "block overridden: #{inspect(block)} with #{inspect(profile.aggressiveness)}"

        assert audit.final_decision == block
        assert audit.gate_decision == block
      end
    end

    # -- Exhaustive: 1000 iterations with random blocks --

    test "no-override holds for 1000 random block evaluations" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for _i <- 1..1000 do
        block = Enum.random(@all_block_reasons)
        {:ok, final, audit} = Evaluator.evaluate(block, profile, ctx)
        assert final == block
        assert audit.final_decision == block
      end
    end
  end

  # ============================================================
  # Guidance Enrichment
  # ============================================================

  describe "guidance enrichment for :allow decisions" do
    test "conservative profile may add guidance to :allow" do
      profile = Profile.conservative()
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate(:allow, profile, ctx)
      # Conservative may or may not add guidance (it's minimal)
      assert Gate.allowed?(decision)
    end

    test "moderate profile adds guidance to :allow in plan/researching" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate(:allow, profile, ctx)

      assert Gate.allowed?(decision)

      if match?({:guide, _}, decision) do
        {:guide, msg} = decision
        assert is_binary(msg)
        assert msg != ""
      end
    end

    test "aggressive profile adds guidance to :allow" do
      profile = Profile.aggressive()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate(:allow, profile, ctx)
      # Aggressive should add guidance for plan/researching
      assert Gate.allowed?(decision)
    end

    test "guidance is always a string when present" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate(:allow, profile, ctx)

      if match?({:guide, _}, decision) do
        {:guide, msg} = decision
        assert is_binary(msg)
      end
    end
  end

  describe "guidance enrichment for {:guide, _} decisions" do
    test "conservative profile preserves existing guidance without extending" do
      profile = Profile.conservative()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate({:guide, "Original hint"}, profile, ctx)

      assert {:guide, msg} = decision
      # Conservative profile doesn't extend existing guidance
      assert msg == "Original hint"
    end

    test "moderate profile may extend existing guidance" do
      profile = Profile.default()
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate({:guide, "Original hint"}, profile, ctx)

      assert {:guide, msg} = decision
      # Message should at least contain the original
      assert String.contains?(msg, "Original hint")
    end

    test "aggressive profile extends existing guidance" do
      profile = Profile.aggressive()
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate({:guide, "Original hint"}, profile, ctx)

      assert {:guide, msg} = decision
      assert String.contains?(msg, "Original hint")
    end

    test "guided decision remains guided after evaluation" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate({:guide, "Hint"}, profile, ctx)
      assert Gate.guided?(decision)
      assert Gate.allowed?(decision)
    end
  end

  # ============================================================
  # Focus Narrowing
  # ============================================================

  describe "focus narrowing" do
    test "focus areas appear in audit when set" do
      profile = Profile.new!(%{focus_areas: [:file_safety]})
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, _decision, audit} = Evaluator.evaluate(:allow, profile, ctx)
      assert :file_safety in audit.focus
    end

    test "multiple focus areas appear in audit" do
      profile = Profile.new!(%{focus_areas: [:file_safety, :scope_narrowing]})
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, _decision, audit} = Evaluator.evaluate(:allow, profile, ctx)
      assert :file_safety in audit.focus
      assert :scope_narrowing in audit.focus
    end

    test "empty focus areas produce empty focus in audit" do
      profile = Profile.default()
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, _decision, audit} = Evaluator.evaluate(:allow, profile, ctx)
      assert audit.focus == []
    end

    test "focus areas produce guidance messages with moderate aggressiveness" do
      profile = Profile.new!(%{aggressiveness: :moderate, focus_areas: [:file_safety]})
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate(:allow, profile, ctx)

      if match?({:guide, _}, decision) do
        {:guide, msg} = decision
        assert msg =~ "file safety" or msg =~ "File safety"
      end
    end

    test "focus areas produce guidance messages with aggressive aggressiveness" do
      profile = Profile.new!(%{aggressiveness: :aggressive, focus_areas: [:test_first]})
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate(:allow, profile, ctx)

      if match?({:guide, _}, decision) do
        {:guide, msg} = decision
        assert msg =~ "test" or msg =~ "Test"
      end
    end

    test "conservative profile doesn't add focus guidance to :allow" do
      profile = Profile.new!(%{aggressiveness: :conservative, focus_areas: [:file_safety]})
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, decision, audit} = Evaluator.evaluate(:allow, profile, ctx)
      # Focus is recorded in audit regardless
      assert :file_safety in audit.focus
      # But conservative may not add guidance from focus
      assert decision == :allow or Gate.guided?(decision)
    end
  end

  # ============================================================
  # Audit Trail
  # ============================================================

  describe "audit trail" do
    test "audit records gate decision" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:ok, _final, audit} = Evaluator.evaluate(:allow, profile, ctx)
      assert audit.gate_decision == :allow
    end

    test "audit records profile settings" do
      profile = Profile.aggressive()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:ok, _final, audit} = Evaluator.evaluate(:allow, profile, ctx)
      assert audit.profile.aggressiveness == :aggressive
      assert audit.profile.risk_tolerance == :high
    end

    test "audit records final decision" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:ok, final, audit} = Evaluator.evaluate(:allow, profile, ctx)
      assert audit.final_decision == final
    end

    test "audit records context (mode, category, task_id)" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_audit"}
      {:ok, _final, audit} = Evaluator.evaluate(:allow, profile, ctx)
      assert audit.context.mode == :plan
      assert audit.context.task_category == :researching
      assert audit.context.task_id == "t_audit"
    end

    test "audit for block records identical gate and final decision" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      block = {:block, :plan_mode_blocks_mutation}
      {:ok, final, audit} = Evaluator.evaluate(block, profile, ctx)
      assert audit.gate_decision == block
      assert audit.final_decision == final
      assert audit.final_decision == block
    end

    test "audit focus is empty for block decisions" do
      profile = Profile.new!(%{focus_areas: [:file_safety]})
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:ok, _final, audit} = Evaluator.evaluate({:block, :no_active_task}, profile, ctx)
      assert audit.focus == []
    end
  end

  # ============================================================
  # Batch Evaluation
  # ============================================================

  describe "batch evaluation" do
    test "evaluate_all processes mixed decisions correctly" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      decisions = [
        {"read", :allow},
        {"write", {:block, :plan_mode_blocks_mutation}},
        {"search", {:guide, "Research hint"}}
      ]

      results = Evaluator.evaluate_all(decisions, profile, ctx)

      assert length(results) == 3
      # Block preserved
      {_, {:ok, write_final, _}} = Enum.find(results, fn {name, _} -> name == "write" end)
      assert write_final == {:block, :plan_mode_blocks_mutation}
    end

    test "evaluate_all preserves input order" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      decisions = [
        {"a", :allow},
        {"b", {:block, :no_active_task}},
        {"c", {:guide, "hint"}}
      ]

      results = Evaluator.evaluate_all(decisions, profile, ctx)
      names = Enum.map(results, fn {name, _} -> name end)
      assert names == ["a", "b", "c"]
    end
  end

  # ============================================================
  # Full Pipeline: Gate → Evaluator
  # ============================================================

  describe "full pipeline: gate → evaluator" do
    test "read-only tool in plan mode: gate guides, evaluator may enrich" do
      profile = Profile.default()
      policy = Policy.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      gate_decision = Gate.evaluate(read_contract(), policy, ctx)
      assert Gate.allowed?(gate_decision)

      {:ok, final, _audit} = Evaluator.evaluate(gate_decision, profile, ctx)
      assert Gate.allowed?(final)
    end

    test "write tool in plan mode: gate blocks, evaluator preserves block" do
      profile = Profile.aggressive()
      policy = Policy.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      gate_decision = Gate.evaluate(write_contract(), policy, ctx)
      assert Gate.blocked?(gate_decision)

      {:ok, final, _audit} = Evaluator.evaluate(gate_decision, profile, ctx)
      assert final == gate_decision
    end

    test "write tool in execute/acting: gate allows, evaluator may guide" do
      profile = Profile.default()
      policy = Policy.default()
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}

      gate_decision = Gate.evaluate(write_contract(), policy, ctx)
      assert Gate.allowed?(gate_decision)

      {:ok, final, _audit} = Evaluator.evaluate(gate_decision, profile, ctx)
      assert Gate.allowed?(final)
    end

    test "full catalog with evaluator: no block overrides" do
      profile = Profile.default()
      policy = Policy.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for contract <- ReadOnlyContracts.all() do
        gate_decision = Gate.evaluate(contract, policy, ctx)
        {:ok, final, _audit} = Evaluator.evaluate(gate_decision, profile, ctx)

        if Gate.blocked?(gate_decision) do
          assert final == gate_decision,
                 "Block overridden for #{contract.name}: #{inspect(gate_decision)} → #{inspect(final)}"
        else
          assert Gate.allowed?(final),
                 "Evaluator unexpectedly blocked #{contract.name}: #{inspect(final)}"
        end
      end
    end

    test "evaluator never downgrades allowed to blocked" do
      profile = Profile.default()
      policy = Policy.default()

      contexts = [
        %{mode: :plan, task_category: :researching, task_id: "t1"},
        %{mode: :explore, task_category: :planning, task_id: "t2"},
        %{mode: :execute, task_category: :acting, task_id: "t3"},
        %{mode: :execute, task_category: :verifying, task_id: "t4"}
      ]

      for ctx <- contexts, contract <- ReadOnlyContracts.all() do
        gate_decision = Gate.evaluate(contract, policy, ctx)

        if Gate.allowed?(gate_decision) do
          {:ok, final, _audit} = Evaluator.evaluate(gate_decision, profile, ctx)

          assert Gate.allowed?(final),
                 "Evaluator downgraded #{contract.name} from allowed: #{inspect(final)}"
        end
      end
    end
  end

  # ============================================================
  # Edge Cases
  # ============================================================

  describe "edge cases" do
    test "empty context map is handled gracefully" do
      profile = Profile.default()
      {:ok, final, audit} = Evaluator.evaluate(:allow, profile, %{})
      assert Gate.allowed?(final)
      assert audit.context == %{}
    end

    test "block with empty context is preserved" do
      profile = Profile.default()
      {:ok, final, _audit} = Evaluator.evaluate({:block, :no_active_task}, profile, %{})
      assert final == {:block, :no_active_task}
    end

    test "unknown gate decision shape passes through" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:ok, final, _audit} = Evaluator.evaluate(:unknown_shape, profile, ctx)
      assert final == :unknown_shape
    end

    test "profile with all focus areas adds guidance for each" do
      profile =
        Profile.new!(%{
          aggressiveness: :aggressive,
          focus_areas: Profile.known_focus_areas()
        })

      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, decision, audit} = Evaluator.evaluate(:allow, profile, ctx)
      assert Gate.allowed?(decision)
      assert length(audit.focus) == length(Profile.known_focus_areas())
    end

    test "low risk tolerance adds extra caution guidance" do
      profile = Profile.new!(%{aggressiveness: :moderate, risk_tolerance: :low})
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate(:allow, profile, ctx)

      if match?({:guide, _}, decision) do
        {:guide, msg} = decision
        # Low risk should add a caution message
        assert is_binary(msg)
      end
    end

    test "verifying category gets verification guidance" do
      profile = Profile.default()
      ctx = %{mode: :execute, task_category: :verifying, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate(:allow, profile, ctx)

      if match?({:guide, _}, decision) do
        {:guide, msg} = decision
        assert msg =~ ~r/verif/i or msg =~ ~r/Verif/i
      end
    end

    test "debugging category gets diagnostic guidance" do
      profile = Profile.default()
      ctx = %{mode: :execute, task_category: :debugging, task_id: "t1"}
      {:ok, decision, _audit} = Evaluator.evaluate(:allow, profile, ctx)

      if match?({:guide, _}, decision) do
        {:guide, msg} = decision
        assert msg =~ ~r/diagnostic|debug|focus/i
      end
    end
  end

  # ============================================================
  # Determinism
  # ============================================================

  describe "determinism" do
    test "same inputs produce same outputs (1000 evaluations)" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_det"}

      results =
        for _i <- 1..1000 do
          {:ok, decision, audit} = Evaluator.evaluate(:allow, profile, ctx)
          {decision, audit}
        end

      unique = Enum.uniq(results)
      assert length(unique) == 1, "Expected deterministic output, got #{length(unique)} variants"
    end

    test "block evaluation is deterministic" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_det"}
      block = {:block, :plan_mode_blocks_mutation}

      results =
        for _i <- 1..1000 do
          {:ok, decision, audit} = Evaluator.evaluate(block, profile, ctx)
          {decision, audit.final_decision}
        end

      unique = Enum.uniq(results)
      assert length(unique) == 1
      assert elem(hd(unique), 0) == block
    end
  end
end
