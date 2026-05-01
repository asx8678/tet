defmodule Tet.TaskManager.GuidanceTest do
  use ExUnit.Case, async: true

  alias Tet.TaskManager.{Guidance, State, Task}

  describe "for_category/1" do
    test "returns research guidance for researching" do
      assert {:guidance, :research, msg} = Guidance.for_category(:researching)
      assert is_binary(msg)
      assert msg =~ "researching"
    end

    test "returns plan guidance for planning" do
      assert {:guidance, :plan, msg} = Guidance.for_category(:planning)
      assert msg =~ "planning"
    end

    test "returns act guidance for acting" do
      assert {:guidance, :act, msg} = Guidance.for_category(:acting)
      assert msg =~ "acting"
    end

    test "returns verify guidance for verifying" do
      assert {:guidance, :verify, msg} = Guidance.for_category(:verifying)
      assert msg =~ "verification"
    end

    test "returns debug guidance for debugging" do
      assert {:guidance, :debug, msg} = Guidance.for_category(:debugging)
      assert msg =~ "debugging"
    end

    test "returns document guidance for documenting" do
      assert {:guidance, :document, msg} = Guidance.for_category(:documenting)
      assert msg =~ "documentation"
    end

    test "all categories produce guidance" do
      for cat <- Task.categories() do
        assert {:guidance, type, msg} = Guidance.for_category(cat)
        assert is_atom(type)
        assert is_binary(msg)
        assert byte_size(msg) > 0
      end
    end
  end

  describe "for_state/1" do
    test "returns :no_active_task when no active task" do
      state = State.new!(%{id: "tm1"})
      assert :no_active_task = Guidance.for_state(state)
    end

    test "returns guidance for the active task's category" do
      state = State.new!(%{id: "tm1"})
      task = Task.new!(%{id: "t1", title: "Test", category: :acting, status: :in_progress})
      {:ok, state} = State.add_task(state, task)
      {:ok, state} = State.set_active(state, "t1")

      assert {:guidance, :act, _msg} = Guidance.for_state(state)
    end
  end

  describe "plan_safe?/1 and acting?/1" do
    test "plan_safe? returns true for researching and planning" do
      assert Guidance.plan_safe?(:researching)
      assert Guidance.plan_safe?(:planning)
    end

    test "plan_safe? returns false for acting categories" do
      refute Guidance.plan_safe?(:acting)
      refute Guidance.plan_safe?(:verifying)
      refute Guidance.plan_safe?(:debugging)
    end

    test "acting? returns true for acting, verifying, debugging, documenting" do
      assert Guidance.acting?(:acting)
      assert Guidance.acting?(:verifying)
      assert Guidance.acting?(:debugging)
      assert Guidance.acting?(:documenting)
    end

    test "acting? returns false for plan-safe categories" do
      refute Guidance.acting?(:researching)
      refute Guidance.acting?(:planning)
    end
  end

  describe "message/1" do
    test "returns message for each category" do
      for cat <- Task.categories() do
        assert is_binary(Guidance.message(cat))
      end
    end

    test "returns nil for unknown category" do
      assert Guidance.message(:unknown) == nil
    end
  end

  describe "category_to_guidance_type/1 and guidance_type_to_category/1" do
    test "round-trips all categories" do
      for cat <- Task.categories() do
        type = Guidance.category_to_guidance_type(cat)
        assert is_atom(type)
        assert Guidance.guidance_type_to_category(type) == cat
      end
    end

    test "unknown guidance type returns nil" do
      assert Guidance.guidance_type_to_category(:unknown) == nil
    end

    test "unknown category maps to :none" do
      assert Guidance.category_to_guidance_type(:teleport) == :none
    end
  end

  describe "all_messages/0" do
    test "returns messages for all categories" do
      messages = Guidance.all_messages()
      assert is_map(messages)
      assert Map.keys(messages) |> Enum.sort() == Task.categories() |> Enum.sort()
    end
  end

  describe "BD-0023 acceptance: categories drive policy" do
    test "plan-safe categories produce read-only guidance" do
      for cat <- [:researching, :planning] do
        {:guidance, _type, msg} = Guidance.for_category(cat)
        assert Guidance.plan_safe?(cat)
        # Plan-safe categories should mention read-only
        assert msg =~ ~r/read.only|Read.only/i
      end
    end

    test "acting categories produce mutation-unlock guidance" do
      for cat <- [:acting, :verifying, :debugging] do
        {:guidance, _type, msg} = Guidance.for_category(cat)
        assert Guidance.acting?(cat)
      end
    end

    test "guidance is consistent with PlanMode.Policy categories" do
      policy = Tet.PlanMode.Policy.default()

      for cat <- Tet.PlanMode.Policy.plan_safe_categories() do
        assert Guidance.plan_safe?(cat) == Tet.PlanMode.Policy.plan_safe_category?(policy, cat)
      end

      for cat <- Tet.PlanMode.Policy.acting_categories() do
        assert Guidance.acting?(cat) == Tet.PlanMode.Policy.acting_category?(policy, cat)
      end
    end
  end
end
