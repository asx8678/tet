defmodule Tet.TaskManagerTest do
  use ExUnit.Case, async: true

  alias Tet.TaskManager

  describe "facade delegates" do
    test "new_task/1 creates a task" do
      assert {:ok, task} =
               TaskManager.new_task(%{id: "t1", title: "Test", category: :researching})

      assert task.id == "t1"
    end

    test "new_state/1 creates a state" do
      assert {:ok, state} = TaskManager.new_state(%{id: "tm1"})
      assert state.id == "tm1"
    end

    test "categories/0 returns all categories" do
      cats = TaskManager.categories()
      assert :researching in cats
      assert :acting in cats
    end

    test "statuses/0 returns all statuses" do
      statuses = TaskManager.statuses()
      assert :pending in statuses
      assert :completed in statuses
    end
  end

  describe "end-to-end task lifecycle" do
    test "full lifecycle: add → start → activate → complete → advance" do
      # Create state
      {:ok, state} = TaskManager.new_state(%{id: "tm_lifecycle"})

      # Add tasks
      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Research", category: :researching})

      {:ok, state} =
        TaskManager.add_task(state, %{
          id: "t2",
          title: "Implement",
          category: :acting,
          dependencies: ["t1"]
        })

      # Start and activate first task
      {:ok, state} = TaskManager.start_and_activate(state, "t1")
      assert TaskManager.active_category(state) == :researching

      # Complete first task and advance
      {:ok, state} = TaskManager.complete_and_advance(state)
      # t1 is completed, but t2 is pending (deps met but not started)
      assert TaskManager.get_task(state, "t1").status == :completed

      # Start second task
      {:ok, state} = TaskManager.start_task(state, "t2")
      {:ok, state} = TaskManager.set_active(state, "t2")
      assert TaskManager.active_category(state) == :acting

      # Complete second task
      {:ok, state} = TaskManager.complete_task(state, "t2")
      assert TaskManager.get_task(state, "t2").status == :completed
      assert state.active_task_id == nil
    end

    test "full lifecycle with failure and retry" do
      {:ok, state} = TaskManager.new_state(%{id: "tm_fail"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Implement", category: :acting})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      assert TaskManager.active_category(state) == :acting

      # Task fails
      {:ok, state} = TaskManager.fail_task(state, "t1")
      assert TaskManager.get_task(state, "t1").status == :failed
      assert state.active_task_id == nil
    end
  end

  describe "category-driven policy" do
    test "guidance changes as category changes" do
      {:ok, state} = TaskManager.new_state(%{id: "tm_policy"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Research", category: :researching})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      assert {:guidance, :research, msg1} = TaskManager.guidance(state)
      assert msg1 =~ "researching"

      # Recategorize to acting
      {:ok, state} = TaskManager.recategorize(state, "t1", :acting)
      assert TaskManager.active_category(state) == :acting

      assert {:guidance, :act, msg2} = TaskManager.guidance(state)
      assert msg2 =~ "acting"
    end

    test "dependency-ordered execution respects categories" do
      {:ok, state} = TaskManager.new_state(%{id: "tm_deps"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "research", title: "Research", category: :researching})

      {:ok, state} =
        TaskManager.add_task(state, %{
          id: "plan",
          title: "Plan",
          category: :planning,
          dependencies: ["research"]
        })

      {:ok, state} =
        TaskManager.add_task(state, %{
          id: "implement",
          title: "Implement",
          category: :acting,
          dependencies: ["plan"]
        })

      # Can't start plan before research is complete
      refute TaskManager.can_start?(state, "plan")
      refute TaskManager.can_start?(state, "implement")

      # Start and complete research
      {:ok, state} = TaskManager.start_task(state, "research")
      {:ok, state} = TaskManager.complete_task(state, "research")
      assert TaskManager.can_start?(state, "plan")
      refute TaskManager.can_start?(state, "implement")

      # Start and complete plan
      {:ok, state} = TaskManager.start_task(state, "plan")
      {:ok, state} = TaskManager.complete_task(state, "plan")
      assert TaskManager.can_start?(state, "implement")
    end
  end

  describe "serialization round-trip" do
    test "state survives to_map/from_map" do
      {:ok, state} = TaskManager.new_state(%{id: "tm_roundtrip"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Test", category: :researching})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      mapped = TaskManager.to_map(state)
      {:ok, restored} = TaskManager.from_map(mapped)

      assert restored.id == state.id
      assert restored.active_task_id == state.active_task_id
      assert Map.keys(restored.tasks) == Map.keys(state.tasks)
    end
  end
end
