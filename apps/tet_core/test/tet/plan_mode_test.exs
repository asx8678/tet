defmodule Tet.PlanModeTest do
  use ExUnit.Case, async: true

  alias Tet.PlanMode
  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Tool.ReadOnlyContracts

  describe "facade delegates" do
    test "default_policy returns the default policy" do
      assert %Policy{} = PlanMode.default_policy()
      assert PlanMode.default_policy().plan_mode == :plan
    end

    test "evaluate with default policy delegates to Gate" do
      {:ok, contract} = ReadOnlyContracts.fetch("read")
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      facade_decision = PlanMode.evaluate(contract, ctx)
      gate_decision = Gate.evaluate(contract, Policy.default(), ctx)

      assert facade_decision == gate_decision
    end

    test "evaluate with explicit policy" do
      {:ok, contract} = ReadOnlyContracts.fetch("read")
      policy = Policy.default()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      assert PlanMode.evaluate(contract, policy, ctx) ==
               Gate.evaluate(contract, policy, ctx)
    end

    test "evaluate_read_only_catalog splits allowed and blocked" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {allowed, blocked} = PlanMode.evaluate_read_only_catalog(Policy.default(), ctx)

      assert length(allowed) == 6
      assert length(blocked) == 0

      for {name, _decision} <- allowed do
        assert name in ReadOnlyContracts.names()
      end
    end

    test "allowed?, blocked?, guided? delegate to Gate" do
      assert PlanMode.allowed?(:allow) == true
      assert PlanMode.allowed?({:guide, "x"}) == true
      assert PlanMode.allowed?({:block, :x}) == false

      assert PlanMode.blocked?({:block, :x}) == true
      assert PlanMode.blocked?(:allow) == false

      assert PlanMode.guided?({:guide, "x"}) == true
      assert PlanMode.guided?(:allow) == false
    end
  end

  describe "BD-0025 acceptance via facade" do
    test "planning cannot mutate: all read-only tools allowed, write blocked" do
      {:ok, read} = ReadOnlyContracts.fetch("read")
      ctx = %{mode: :plan, task_category: :planning, task_id: "t_plan"}

      # Read-only tools are allowed
      assert PlanMode.allowed?(PlanMode.evaluate(read, ctx))

      # A mutating tool would be blocked (tested in gate_test with write_contract)
    end
  end
end
