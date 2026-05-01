defmodule Tet.PlanMode.EvaluatorFacadeTest do
  @moduledoc """
  BD-0032: PlanMode facade integration with the steering evaluator.

  Tests the `Tet.PlanMode.steer/3` and `Tet.PlanMode.evaluate_and_steer/4`
  facade functions that compose the gate (Ring-1) with the evaluator (Ring-2).
  """
  use ExUnit.Case, async: true

  alias Tet.PlanMode
  alias Tet.PlanMode.Evaluator.Profile
  alias Tet.PlanMode.Gate
  alias Tet.PlanMode.Policy

  import Tet.PlanMode.GateTestHelpers

  describe "PlanMode.steer/3" do
    test "blocks pass through unchanged" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      block = {:block, :plan_mode_blocks_mutation}

      {:ok, final, audit} = PlanMode.steer(block, profile, ctx)
      assert final == block
      assert audit.gate_decision == block
    end

    test "allowed decisions may get guidance" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      {:ok, final, _audit} = PlanMode.steer(:allow, profile, ctx)
      assert Gate.allowed?(final)
    end
  end

  describe "PlanMode.evaluate_and_steer/4" do
    test "full pipeline: read-only in plan mode gets gate guidance then evaluator" do
      profile = Profile.default()
      policy = Policy.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      {:ok, final, audit} = PlanMode.evaluate_and_steer(read_contract(), policy, ctx, profile)
      assert Gate.allowed?(final)
      assert audit.gate_decision != nil
    end

    test "full pipeline: write in plan mode is blocked through evaluator" do
      profile = Profile.aggressive()
      policy = Policy.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      {:ok, final, audit} = PlanMode.evaluate_and_steer(write_contract(), policy, ctx, profile)
      assert Gate.blocked?(final)
      assert audit.final_decision == final
    end

    test "full pipeline: write in execute/acting is allowed" do
      profile = Profile.default()
      policy = Policy.default()
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}

      {:ok, final, _audit} = PlanMode.evaluate_and_steer(write_contract(), policy, ctx, profile)
      assert Gate.allowed?(final)
    end

    test "default evaluator profile accessible from facade" do
      assert PlanMode.default_evaluator_profile() == Profile.default()
    end
  end

  describe "PlanMode.verify_no_override/3" do
    test "returns :ok for all known block reasons" do
      profile = Profile.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      blocks = [
        {:block, :no_active_task},
        {:block, :invalid_context},
        {:block, :mode_not_allowed},
        {:block, :plan_mode_blocks_mutation},
        {:block, :category_blocks_tool}
      ]

      assert :ok = PlanMode.verify_no_override(blocks, profile, ctx)
    end
  end
end
