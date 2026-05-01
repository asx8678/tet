defmodule Tet.Repair.SafeRelease.PipelineTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  alias Tet.Repair.SafeRelease.Pipeline

  describe "steps/0" do
    test "returns all pipeline steps in canonical order" do
      assert Pipeline.steps() == [
               :diagnose,
               :plan,
               :approve,
               :checkpoint,
               :patch,
               :compile,
               :smoke,
               :handoff
             ]
    end

    test "starts with diagnose and ends with handoff" do
      steps = Pipeline.steps()
      assert hd(steps) == :diagnose
      assert List.last(steps) == :handoff
    end

    test "contains exactly 8 steps" do
      assert length(Pipeline.steps()) == 8
    end
  end

  describe "step_config/1" do
    test "returns config for every known step" do
      for step <- Pipeline.steps() do
        assert {:ok, config} = Pipeline.step_config(step)
        assert is_binary(config.description)
        assert is_boolean(config.required)
        assert is_integer(config.timeout) and config.timeout > 0
      end
    end

    test "diagnose is required" do
      assert {:ok, %{required: true}} = Pipeline.step_config(:diagnose)
    end

    test "plan is required" do
      assert {:ok, %{required: true}} = Pipeline.step_config(:plan)
    end

    test "approve is optional" do
      assert {:ok, %{required: false}} = Pipeline.step_config(:approve)
    end

    test "checkpoint is optional" do
      assert {:ok, %{required: false}} = Pipeline.step_config(:checkpoint)
    end

    test "patch is required" do
      assert {:ok, %{required: true}} = Pipeline.step_config(:patch)
    end

    test "compile is required" do
      assert {:ok, %{required: true}} = Pipeline.step_config(:compile)
    end

    test "smoke is required" do
      assert {:ok, %{required: true}} = Pipeline.step_config(:smoke)
    end

    test "handoff is required" do
      assert {:ok, %{required: true}} = Pipeline.step_config(:handoff)
    end

    test "returns error for unknown step" do
      assert {:error, :unknown_step} = Pipeline.step_config(:teleport)
      assert {:error, :unknown_step} = Pipeline.step_config(:rollback)
    end
  end

  describe "validate_step_order/1" do
    test "accepts the full canonical order" do
      assert :ok = Pipeline.validate_step_order(Pipeline.steps())
    end

    test "accepts valid subsequences" do
      assert :ok = Pipeline.validate_step_order([:diagnose, :patch, :handoff])
      assert :ok = Pipeline.validate_step_order([:diagnose, :compile, :smoke])
      assert :ok = Pipeline.validate_step_order([:plan, :checkpoint])
    end

    test "accepts empty list" do
      assert :ok = Pipeline.validate_step_order([])
    end

    test "accepts single step" do
      for step <- Pipeline.steps() do
        assert :ok = Pipeline.validate_step_order([step])
      end
    end

    test "rejects reversed order" do
      assert {:error, :invalid_step_order} =
               Pipeline.validate_step_order([:handoff, :diagnose])
    end

    test "rejects out-of-order adjacent steps" do
      assert {:error, :invalid_step_order} =
               Pipeline.validate_step_order([:compile, :patch])
    end

    test "rejects duplicates" do
      assert {:error, :invalid_step_order} =
               Pipeline.validate_step_order([:diagnose, :diagnose])
    end

    test "rejects unknown steps" do
      assert {:error, {:unknown_steps, [:teleport]}} =
               Pipeline.validate_step_order([:diagnose, :teleport, :handoff])
    end

    test "reports all unknown steps" do
      assert {:error, {:unknown_steps, [:warp, :teleport]}} =
               Pipeline.validate_step_order([:warp, :teleport])
    end
  end

  describe "can_skip?/1" do
    test "approve can be skipped" do
      assert Pipeline.can_skip?(:approve)
    end

    test "checkpoint can be skipped" do
      assert Pipeline.can_skip?(:checkpoint)
    end

    test "required steps cannot be skipped" do
      for step <- [:diagnose, :plan, :patch, :compile, :smoke, :handoff] do
        refute Pipeline.can_skip?(step), "expected #{step} to not be skippable"
      end
    end

    test "skippable steps match non-required step configs" do
      for step <- Pipeline.steps() do
        {:ok, config} = Pipeline.step_config(step)
        assert Pipeline.can_skip?(step) == not config.required
      end
    end
  end
end
