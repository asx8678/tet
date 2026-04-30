defmodule Tet.PlanMode.PolicyTest do
  use ExUnit.Case, async: true

  alias Tet.PlanMode.Policy

  describe "default policy" do
    test "builds with no attrs and matches Phase 7 spec" do
      policy = Policy.default()

      assert %Policy{} = policy
      assert policy.plan_mode == :plan
      assert :plan in policy.safe_modes
      assert :explore in policy.safe_modes
      assert :researching in policy.plan_safe_categories
      assert :planning in policy.plan_safe_categories
      assert :acting in policy.acting_categories
      assert :verifying in policy.acting_categories
      assert :debugging in policy.acting_categories
      assert :documenting in policy.acting_categories
      assert policy.require_active_task == true
    end

    test "plan_safe_categories and acting_categories have no overlap" do
      policy = Policy.default()
      plan_set = MapSet.new(policy.plan_safe_categories)
      acting_set = MapSet.new(policy.acting_categories)
      assert MapSet.disjoint?(plan_set, acting_set)
    end
  end

  describe "new/1 validation" do
    test "rejects overlapping categories" do
      assert {:error, {:policy_category_overlap, [:researching]}} =
               Policy.new(%{
                 plan_safe_categories: [:researching],
                 acting_categories: [:researching]
               })
    end

    test "rejects empty safe_modes" do
      assert {:error, {:invalid_policy_field, :safe_modes}} =
               Policy.new(%{safe_modes: []})
    end

    test "rejects non-atom plan_mode" do
      assert {:error, {:invalid_policy_field, :plan_mode}} =
               Policy.new(%{plan_mode: "not_an_atom"})
    end

    test "rejects non-boolean require_active_task" do
      assert {:error, {:invalid_policy_field, :require_active_task}} =
               Policy.new(%{require_active_task: "yes"})
    end

    test "builds custom policy" do
      assert {:ok, policy} =
               Policy.new(%{
                 plan_mode: :explore,
                 safe_modes: [:explore],
                 plan_safe_categories: [:researching],
                 acting_categories: [:acting],
                 require_active_task: false
               })

      assert policy.plan_mode == :explore
      assert policy.safe_modes == [:explore]
      assert policy.plan_safe_categories == [:researching]
      assert policy.acting_categories == [:acting]
      assert policy.require_active_task == false
    end
  end

  describe "mode queries" do
    test "plan_safe_mode? returns true for plan and explore" do
      policy = Policy.default()
      assert Policy.plan_safe_mode?(policy, :plan) == true
      assert Policy.plan_safe_mode?(policy, :explore) == true
      assert Policy.plan_safe_mode?(policy, :execute) == false
      assert Policy.plan_safe_mode?(policy, :repair) == false
    end

    test "plan_safe_category? returns true for researching and planning" do
      policy = Policy.default()
      assert Policy.plan_safe_category?(policy, :researching) == true
      assert Policy.plan_safe_category?(policy, :planning) == true
      assert Policy.plan_safe_category?(policy, :acting) == false
      assert Policy.plan_safe_category?(policy, :verifying) == false
    end

    test "acting_category? returns true for acting categories" do
      policy = Policy.default()
      assert Policy.acting_category?(policy, :acting) == true
      assert Policy.acting_category?(policy, :verifying) == true
      assert Policy.acting_category?(policy, :debugging) == true
      assert Policy.acting_category?(policy, :documenting) == true
      assert Policy.acting_category?(policy, :researching) == false
      assert Policy.acting_category?(policy, :planning) == false
    end
  end

  describe "contract classification" do
    test "read_only_contract? returns true for BD-0020 read-only contracts" do
      for contract <- Tet.Tool.read_only_contracts() do
        assert Policy.read_only_contract?(contract) == true,
               "expected #{contract.name} to be read-only"
      end
    end

    test "contract_allows_mode? checks contract modes" do
      {:ok, list_contract} = Tet.Tool.ReadOnlyContracts.fetch("list")
      assert Policy.contract_allows_mode?(list_contract, :plan) == true
      assert Policy.contract_allows_mode?(list_contract, :execute) == true
      assert Policy.contract_allows_mode?(list_contract, :chat) == false
    end

    test "contract_allows_category? checks contract task_categories" do
      {:ok, read_contract} = Tet.Tool.ReadOnlyContracts.fetch("read")
      assert Policy.contract_allows_category?(read_contract, :researching) == true
      assert Policy.contract_allows_category?(read_contract, :acting) == true
    end
  end

  describe "all_categories/0" do
    test "covers both plan-safe and acting categories" do
      all = Policy.all_categories()
      plan_safe = Policy.plan_safe_categories()
      acting = Policy.acting_categories()

      for cat <- plan_safe ++ acting do
        assert cat in all, "expected #{cat} in all_categories"
      end
    end
  end
end
