defmodule Tet.TaskManager.StateTest do
  use ExUnit.Case, async: true

  alias Tet.TaskManager.{State, Task}

  describe "new/1 validates required fields" do
    test "creates a valid empty state" do
      assert {:ok, state} = State.new(%{id: "tm1"})
      assert state.id == "tm1"
      assert state.tasks == %{}
      assert state.active_task_id == nil
      assert state.metadata == %{}
    end

    test "creates state with initial tasks" do
      task = Task.new!(%{id: "t1", title: "Test", category: :researching})
      assert {:ok, state} = State.new(%{id: "tm1", tasks: %{"t1" => task}})
      assert Map.has_key?(state.tasks, "t1")
    end

    test "rejects missing id" do
      assert {:error, {:invalid_task_manager_field, :id}} = State.new(%{})
    end

    test "rejects empty id" do
      assert {:error, {:invalid_task_manager_field, :id}} = State.new(%{id: ""})
    end

    test "validates active task must be in_progress" do
      task = Task.new!(%{id: "t1", title: "Test", category: :researching})
      # pending task can't be active
      assert {:error, {:active_task_not_in_progress, "t1", :pending}} =
               State.new(%{id: "tm1", tasks: %{"t1" => task}, active_task_id: "t1"})
    end

    test "allows in_progress task as active" do
      task = Task.new!(%{id: "t1", title: "Test", category: :researching, status: :in_progress})
      assert {:ok, state} = State.new(%{id: "tm1", tasks: %{"t1" => task}, active_task_id: "t1"})
      assert state.active_task_id == "t1"
    end

    test "rejects unknown active task" do
      assert {:error, {:task_not_found, "ghost"}} =
               State.new(%{id: "tm1", active_task_id: "ghost"})
    end
  end

  describe "add_task/2" do
    setup do
      state = State.new!(%{id: "tm1"})
      {:ok, state: state}
    end

    test "adds a task via struct", %{state: state} do
      task = Task.new!(%{id: "t1", title: "Research", category: :researching})
      assert {:ok, state} = State.add_task(state, task)
      assert State.get_task(state, "t1") == task
    end

    test "adds a task via attrs map", %{state: state} do
      assert {:ok, state} = State.add_task(state, %{id: "t1", title: "Research", category: :researching})
      assert State.get_task(state, "t1").category == :researching
    end

    test "rejects duplicate task ID", %{state: state} do
      task = Task.new!(%{id: "t1", title: "Research", category: :researching})
      {:ok, state} = State.add_task(state, task)
      assert {:error, {:duplicate_task_id, "t1"}} = State.add_task(state, task)
    end

    test "rejects unknown dependencies", %{state: state} do
      assert {:error, {:unknown_dependencies, ["ghost"]}} =
               State.add_task(state, %{id: "t1", title: "Test", category: :acting, dependencies: ["ghost"]})
    end

    test "allows task with satisfied dependencies" do
      state = add_simple_task(state(), "dep1", :researching)
      {:ok, dep1} = State.start_task(state, "dep1")
      {:ok, dep1} = State.complete_task(dep1, "dep1")

      assert {:ok, state} =
               State.add_task(dep1, %{
                 id: "t1",
                 title: "Test",
                 category: :acting,
                 dependencies: ["dep1"]
               })

      assert State.can_start?(state, "t1")
    end

    test "adds task with unsatisfied deps (still valid to add, just can't start)" do
      state = add_simple_task(state(), "dep1", :researching)

      assert {:ok, state} =
               State.add_task(state, %{
                 id: "t1",
                 title: "Test",
                 category: :acting,
                 dependencies: ["dep1"]
               })

      refute State.can_start?(state, "t1")
    end
  end

  describe "transition/3 and helpers" do
    setup do
      state = State.new!(%{id: "tm1"})
      {:ok, state: add_simple_task(state, "t1", :acting)}
    end

    test "start_task/2 transitions pending → in_progress", %{state: state} do
      assert {:ok, state} = State.start_task(state, "t1")
      assert State.get_task(state, "t1").status == :in_progress
    end

    test "start_task/2 rejects when deps unsatisfied" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "dep1", :researching)
      {:ok, state} = State.add_task(state, %{id: "t1", title: "Test", category: :acting, dependencies: ["dep1"]})

      assert {:error, {:unmet_dependencies, "t1", ["dep1"]}} = State.start_task(state, "t1")
    end

    test "complete_task/2 transitions in_progress → completed", %{state: state} do
      {:ok, state} = State.start_task(state, "t1")
      assert {:ok, state} = State.complete_task(state, "t1")
      assert State.get_task(state, "t1").status == :completed
    end

    test "fail_task/2 transitions in_progress → failed", %{state: state} do
      {:ok, state} = State.start_task(state, "t1")
      assert {:ok, state} = State.fail_task(state, "t1")
      assert State.get_task(state, "t1").status == :failed
    end

    test "cancel_task/2 transitions pending → cancelled" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      assert {:ok, state} = State.cancel_task(state, "t1")
      assert State.get_task(state, "t1").status == :cancelled
    end

    test "cancel_task/2 transitions in_progress → cancelled", %{state: state} do
      {:ok, state} = State.start_task(state, "t1")
      assert {:ok, state} = State.cancel_task(state, "t1")
      assert State.get_task(state, "t1").status == :cancelled
    end

    test "rejects invalid transition (pending → completed)", %{state: state} do
      assert {:error, {:invalid_task_transition, :pending, :completed}} =
               State.complete_task(state, "t1")
    end

    test "rejects transition for unknown task" do
      state = State.new!(%{id: "tm1"})
      assert {:error, {:task_not_found, "ghost"}} = State.start_task(state, "ghost")
    end
  end

  describe "active task clearing on terminal transition" do
    test "completing the active task clears active_task_id" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state} = State.set_active(state, "t1")
      assert state.active_task_id == "t1"

      {:ok, state} = State.complete_task(state, "t1")
      assert state.active_task_id == nil
    end

    test "failing the active task clears active_task_id" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state} = State.set_active(state, "t1")

      {:ok, state} = State.fail_task(state, "t1")
      assert state.active_task_id == nil
    end

    test "cancelling the active task clears active_task_id" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state} = State.set_active(state, "t1")

      {:ok, state} = State.cancel_task(state, "t1")
      assert state.active_task_id == nil
    end

    test "completing a non-active task does not clear active_task_id" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      state = add_simple_task(state, "t2", :acting)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state} = State.start_task(state, "t2")
      {:ok, state} = State.set_active(state, "t1")

      {:ok, state} = State.complete_task(state, "t2")
      assert state.active_task_id == "t1"
    end
  end

  describe "set_active/2" do
    setup do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state: state}
    end

    test "sets active task to an in_progress task", %{state: state} do
      assert {:ok, state} = State.set_active(state, "t1")
      assert state.active_task_id == "t1"
    end

    test "rejects pending task as active" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      assert {:error, {:active_task_not_in_progress, "t1", :pending}} = State.set_active(state, "t1")
    end

    test "rejects completed task as active" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state} = State.complete_task(state, "t1")

      assert {:error, {:active_task_not_in_progress, "t1", :completed}} = State.set_active(state, "t1")
    end

    test "rejects unknown task as active", %{state: state} do
      assert {:error, {:task_not_found, "ghost"}} = State.set_active(state, "ghost")
    end
  end

  describe "clear_active/1" do
    test "clears active task" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state} = State.set_active(state, "t1")
      assert state.active_task_id == "t1"

      state = State.clear_active(state)
      assert state.active_task_id == nil
    end
  end

  describe "active_task/1 and active_category/1" do
    test "returns nil when no active task" do
      state = State.new!(%{id: "tm1"})
      assert State.active_task(state) == nil
      assert State.active_category(state) == nil
    end

    test "returns active task and category" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :researching)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state} = State.set_active(state, "t1")

      assert %Task{id: "t1"} = State.active_task(state)
      assert State.active_category(state) == :researching
    end
  end

  describe "select_next/1" do
    test "selects the first in_progress task with all deps met" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :researching)
      {:ok, state} = State.start_task(state, "t1")

      assert {:ok, state} = State.select_next(state)
      assert state.active_task_id == "t1"
    end

    test "skips in_progress tasks with unmet deps" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "dep1", :researching)
      {:ok, state} = State.add_task(state, %{id: "t1", title: "Test", category: :acting, dependencies: ["dep1"]})
      # Manually set t1 to in_progress (bypass dep check) for this select_next test
      task = State.get_task(state, "t1")
      {:ok, in_progress_task} = Task.transition(task, :in_progress)
      state = %{state | tasks: Map.put(state.tasks, "t1", in_progress_task)}

      {:ok, state} = State.select_next(state)
      # t1 has unmet dep, no eligible task
      assert state.active_task_id == nil
    end

    test "selects eligible task when deps are met" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "dep1", :researching)
      {:ok, state} = State.add_task(state, %{id: "t1", title: "Test", category: :acting, dependencies: ["dep1"]})
      # Complete the dependency first, then start t1
      {:ok, state} = State.start_task(state, "dep1")
      {:ok, state} = State.complete_task(state, "dep1")
      {:ok, state} = State.start_task(state, "t1")

      {:ok, state} = State.select_next(state)
      assert state.active_task_id == "t1"
    end

    test "returns state unchanged when no eligible task" do
      state = State.new!(%{id: "tm1"})
      assert {:ok, state2} = State.select_next(state)
      assert state2.active_task_id == nil
    end
  end

  describe "dependencies" do
    test "add_dependency/3 adds a dependency" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      state = add_simple_task(state, "t2", :acting)

      assert {:ok, state} = State.add_dependency(state, "t1", "t2")
      assert State.get_task(state, "t1").dependencies == ["t2"]
    end

    test "add_dependency/3 rejects unknown dep" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)

      assert {:error, {:task_not_found, "ghost"}} = State.add_dependency(state, "t1", "ghost")
    end

    test "add_dependency/3 rejects circular dependency" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      state = add_simple_task(state, "t2", :acting, dependencies: ["t1"])

      assert {:error, {:circular_dependency, "t1"}} = State.add_dependency(state, "t1", "t2")
    end

    test "add_dependency/3 detects transitive cycles" do
      # t1 depends on t2, t2 depends on t3
      # Try to add t3 depends on t1 → t3→t1→t2→t3 (cycle!)
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t3", :acting)
      state = add_simple_task(state, "t2", :acting, dependencies: ["t3"])
      state = add_simple_task(state, "t1", :acting, dependencies: ["t2"])

      assert {:error, {:circular_dependency, "t3"}} = State.add_dependency(state, "t3", "t1")
    end

    test "remove_dependency/3 removes a dependency" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      state = add_simple_task(state, "t2", :acting)
      {:ok, state} = State.add_dependency(state, "t1", "t2")

      assert {:ok, state} = State.remove_dependency(state, "t1", "t2")
      assert State.get_task(state, "t1").dependencies == []
    end

    test "dependencies_satisfied?/2 checks completion" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "dep1", :researching)
      state = add_simple_task(state, "t1", :acting, dependencies: ["dep1"])

      refute State.dependencies_satisfied?(state, "t1")

      {:ok, state} = State.start_task(state, "dep1")
      {:ok, state} = State.complete_task(state, "dep1")
      assert State.dependencies_satisfied?(state, "t1")
    end

    test "can_start?/2 checks pending + deps met" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "dep1", :researching)
      state = add_simple_task(state, "t1", :acting, dependencies: ["dep1"])

      refute State.can_start?(state, "t1")

      {:ok, state} = State.start_task(state, "dep1")
      {:ok, state} = State.complete_task(state, "dep1")
      assert State.can_start?(state, "t1")
    end
  end

  describe "recategorize/3" do
    test "changes category" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :researching)

      assert {:ok, state} = State.recategorize(state, "t1", :acting)
      assert State.get_task(state, "t1").category == :acting
    end

    test "rejects recategorize of terminal task" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :acting)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state} = State.complete_task(state, "t1")

      assert {:error, {:terminal_task_recategorize, :completed}} =
               State.recategorize(state, "t1", :researching)
    end
  end

  describe "listing and filtering" do
    setup do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :researching, %{status: :in_progress})
      state = add_simple_task(state, "t2", :acting)
      state = add_simple_task(state, "t3", :acting, %{status: :completed})
      {:ok, state: state}
    end

    test "list_tasks/1 returns all tasks", %{state: state} do
      tasks = State.list_tasks(state)
      assert length(tasks) == 3
    end

    test "tasks_by_status/2 filters by status", %{state: state} do
      pending = State.tasks_by_status(state, :pending)
      assert length(pending) == 1
      in_progress = State.tasks_by_status(state, :in_progress)
      assert length(in_progress) == 1
      completed = State.tasks_by_status(state, :completed)
      assert length(completed) == 1
    end

    test "tasks_by_category/2 filters by category", %{state: state} do
      researching = State.tasks_by_category(state, :researching)
      assert length(researching) == 1
      acting = State.tasks_by_category(state, :acting)
      assert length(acting) == 2
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips state through serialization" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :researching)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state} = State.set_active(state, "t1")

      mapped = State.to_map(state)
      assert mapped.id == "tm1"
      assert mapped.active_task_id == "t1"
      assert is_map(mapped.tasks)

      assert {:ok, roundtripped} = State.from_map(mapped)
      assert roundtripped.id == state.id
      assert roundtripped.active_task_id == state.active_task_id
      assert Map.keys(roundtripped.tasks) == Map.keys(state.tasks)
    end

    test "round-trips empty state" do
      state = State.new!(%{id: "tm_empty"})
      mapped = State.to_map(state)
      assert {:ok, roundtripped} = State.from_map(mapped)
      assert roundtripped.id == "tm_empty"
      assert roundtripped.tasks == %{}
    end
  end

  describe "guidance/1" do
    test "returns guidance for active task" do
      state = State.new!(%{id: "tm1"})
      state = add_simple_task(state, "t1", :researching)
      {:ok, state} = State.start_task(state, "t1")
      {:ok, state} = State.set_active(state, "t1")

      assert {:guidance, :research, msg} = State.guidance(state)
      assert is_binary(msg)
      assert msg =~ "researching"
    end

    test "returns :no_active_task when no active task" do
      state = State.new!(%{id: "tm1"})
      assert :no_active_task = State.guidance(state)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp state(), do: State.new!(%{id: "tm1"})

  defp add_simple_task(state, id, category, overrides \\ []) do
    base = %{id: id, title: "Task #{id}", category: category}
    attrs = Map.merge(base, Enum.into(overrides, %{}))

    case State.add_task(state, attrs) do
      {:ok, state} -> state
      {:error, reason} -> flunk("Failed to add task #{id}: #{inspect(reason)}")
    end
  end
end
