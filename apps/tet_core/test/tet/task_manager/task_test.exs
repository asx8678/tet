defmodule Tet.TaskManager.TaskTest do
  use ExUnit.Case, async: true

  alias Tet.TaskManager.Task

  describe "new/1 validates required fields" do
    test "creates a valid task with required fields" do
      assert {:ok, task} = Task.new(%{id: "t1", title: "Research auth", category: :researching})
      assert task.id == "t1"
      assert task.title == "Research auth"
      assert task.category == :researching
      assert task.status == :pending
      assert task.dependencies == []
      assert task.parent_id == nil
      assert task.metadata == %{}
    end

    test "creates a task with all optional fields" do
      assert {:ok, task} =
               Task.new(%{
                 id: "t2",
                 title: "Implement auth",
                 category: :acting,
                 parent_id: "t1",
                 status: :in_progress,
                 dependencies: ["t1"],
                 metadata: %{"priority" => "high"}
               })

      assert task.parent_id == "t1"
      assert task.status == :in_progress
      assert task.dependencies == ["t1"]
      assert task.metadata == %{"priority" => "high"}
    end

    test "rejects empty id" do
      assert {:error, {:invalid_task_field, :id}} =
               Task.new(%{id: "", title: "Test", category: :researching})
    end

    test "rejects missing title" do
      assert {:error, {:invalid_task_field, :title}} =
               Task.new(%{id: "t1", category: :researching})
    end

    test "rejects invalid category" do
      assert {:error, {:invalid_task_field, :category}} =
               Task.new(%{id: "t1", title: "Test", category: :invalid})
    end

    test "accepts string category and normalizes to atom" do
      assert {:ok, task} = Task.new(%{id: "t1", title: "Test", category: "researching"})
      assert task.category == :researching
    end

    test "accepts string status and normalizes to atom" do
      assert {:ok, task} =
               Task.new(%{id: "t1", title: "Test", category: :acting, status: "in_progress"})

      assert task.status == :in_progress
    end

    test "rejects invalid string category" do
      assert {:error, {:invalid_task_field, :category}} =
               Task.new(%{id: "t1", title: "Test", category: "frobnicating"})
    end

    test "rejects invalid string status" do
      assert {:error, {:invalid_task_field, :status}} =
               Task.new(%{id: "t1", title: "Test", category: :acting, status: "zombie"})
    end

    test "rejects self-referencing parent" do
      assert {:error, {:self_referencing_parent, "t1"}} =
               Task.new(%{id: "t1", title: "Test", category: :acting, parent_id: "t1"})
    end

    test "rejects self-dependency" do
      assert {:error, {:self_dependency, "t1"}} =
               Task.new(%{id: "t1", title: "Test", category: :acting, dependencies: ["t1"]})
    end

    test "rejects non-binary dependency IDs" do
      assert {:error, {:invalid_task_field, :dependencies}} =
               Task.new(%{id: "t1", title: "Test", category: :acting, dependencies: [123]})
    end

    test "rejects empty string dependency IDs" do
      assert {:error, {:invalid_task_field, :dependencies}} =
               Task.new(%{id: "t1", title: "Test", category: :acting, dependencies: [""]})
    end
  end

  describe "new!/1" do
    test "builds task or raises" do
      task = Task.new!(%{id: "t1", title: "Test", category: :researching})
      assert task.id == "t1"

      assert_raise ArgumentError, ~r/invalid task/, fn ->
        Task.new!(%{id: "", title: "Test", category: :researching})
      end
    end
  end

  describe "transitions" do
    test "pending → in_progress" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting})
      assert {:ok, started} = Task.start(task)
      assert started.status == :in_progress
    end

    test "pending → cancelled" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting})
      assert {:ok, cancelled} = Task.cancel(task)
      assert cancelled.status == :cancelled
    end

    test "in_progress → completed" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting, status: :in_progress})
      assert {:ok, completed} = Task.complete(task)
      assert completed.status == :completed
    end

    test "in_progress → failed" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting, status: :in_progress})
      assert {:ok, failed} = Task.fail(task)
      assert failed.status == :failed
    end

    test "in_progress → cancelled" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting, status: :in_progress})
      assert {:ok, cancelled} = Task.cancel(task)
      assert cancelled.status == :cancelled
    end

    test "rejects invalid transitions" do
      # pending → completed (skip in_progress)
      task = Task.new!(%{id: "t1", title: "Test", category: :acting})
      assert {:error, {:invalid_task_transition, :pending, :completed}} = Task.complete(task)

      # pending → failed
      assert {:error, {:invalid_task_transition, :pending, :failed}} = Task.fail(task)
    end

    test "terminal states reject all transitions" do
      for status <- [:completed, :failed, :cancelled] do
        task = Task.new!(%{id: "t#{status}", title: "Test", category: :acting, status: status})

        for target <- [:in_progress, :completed, :failed, :cancelled, :pending] do
          assert {:error, _} = Task.transition(task, target)
        end
      end
    end

    test "all legal transitions succeed" do
      for {from, to} <- Task.transitions() do
        task = Task.new!(%{id: "t_#{from}_#{to}", title: "Test", category: :acting, status: from})
        assert {:ok, updated} = Task.transition(task, to)
        assert updated.status == to
      end
    end
  end

  describe "recategorize/2" do
    test "changes category of a non-terminal task" do
      task = Task.new!(%{id: "t1", title: "Test", category: :researching})
      assert {:ok, recategorized} = Task.recategorize(task, :acting)
      assert recategorized.category == :acting
    end

    test "rejects invalid category" do
      task = Task.new!(%{id: "t1", title: "Test", category: :researching})

      assert {:error, {:invalid_task_category, :teleporting}} =
               Task.recategorize(task, :teleporting)
    end

    test "rejects recategorize of terminal task" do
      for status <- [:completed, :failed, :cancelled] do
        task = Task.new!(%{id: "t1", title: "Test", category: :acting, status: status})

        assert {:error, {:terminal_task_recategorize, ^status}} =
                 Task.recategorize(task, :researching)
      end
    end
  end

  describe "add_dependency/2 and remove_dependency/2" do
    test "adds a dependency to a non-terminal task" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting})
      assert {:ok, updated} = Task.add_dependency(task, "dep1")
      assert updated.dependencies == ["dep1"]
    end

    test "adds multiple dependencies" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting})
      {:ok, task} = Task.add_dependency(task, "dep1")
      {:ok, task} = Task.add_dependency(task, "dep2")
      assert task.dependencies == ["dep1", "dep2"]
    end

    test "idempotent add" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting, dependencies: ["dep1"]})
      assert {:ok, task2} = Task.add_dependency(task, "dep1")
      assert task2.dependencies == ["dep1"]
    end

    test "rejects self-dependency" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting})
      assert {:error, {:self_dependency, "t1"}} = Task.add_dependency(task, "t1")
    end

    test "rejects nil dependency" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting})
      assert {:error, {:invalid_dependency_id, nil}} = Task.add_dependency(task, nil)
    end

    test "removes a dependency" do
      task =
        Task.new!(%{id: "t1", title: "Test", category: :acting, dependencies: ["dep1", "dep2"]})

      assert {:ok, updated} = Task.remove_dependency(task, "dep1")
      assert updated.dependencies == ["dep2"]
    end

    test "no-op remove when dep not present" do
      task = Task.new!(%{id: "t1", title: "Test", category: :acting, dependencies: ["dep1"]})
      assert {:ok, updated} = Task.remove_dependency(task, "dep_nonexistent")
      assert updated.dependencies == ["dep1"]
    end

    test "rejects add to terminal task" do
      for status <- [:completed, :failed, :cancelled] do
        task = Task.new!(%{id: "t1", title: "Test", category: :acting, status: status})
        assert {:error, {:terminal_task_mutation, ^status}} = Task.add_dependency(task, "dep1")
      end
    end

    test "rejects remove from terminal task" do
      for status <- [:completed, :failed, :cancelled] do
        task =
          Task.new!(%{
            id: "t1",
            title: "Test",
            category: :acting,
            status: status,
            dependencies: ["dep1"]
          })

        assert {:error, {:terminal_task_mutation, ^status}} = Task.remove_dependency(task, "dep1")
      end
    end
  end

  describe "to_map/1 and from_map/1" do
    test "round-trips a task through serialization" do
      task =
        Task.new!(%{
          id: "t1",
          title: "Test task",
          category: :acting,
          parent_id: "p1",
          status: :in_progress,
          dependencies: ["d1", "d2"],
          metadata: %{"priority" => "high"}
        })

      mapped = Task.to_map(task)
      assert mapped.id == "t1"
      assert mapped.category == "acting"
      assert mapped.status == "in_progress"
      assert mapped.dependencies == ["d1", "d2"]

      assert {:ok, roundtripped} = Task.from_map(mapped)
      assert roundtripped == task
    end

    test "round-trips with string keys" do
      attrs = %{
        "id" => "t1",
        "title" => "Test task",
        "category" => "researching",
        "status" => "pending"
      }

      assert {:ok, task} = Task.from_map(attrs)
      assert task.id == "t1"
      assert task.category == :researching
    end
  end

  describe "categories and statuses" do
    test "categories match Policy.all_categories" do
      assert Task.categories() == Tet.PlanMode.Policy.all_categories()
    end

    test "all categories are known atoms" do
      for cat <- Task.categories() do
        assert is_atom(cat)
      end
    end

    test "terminal? returns true only for terminal statuses" do
      assert Task.terminal?(:completed)
      assert Task.terminal?(:failed)
      assert Task.terminal?(:cancelled)
      refute Task.terminal?(:pending)
      refute Task.terminal?(:in_progress)
    end

    test "plan_safe_category? is consistent with Policy" do
      assert Task.plan_safe_category?(:researching)
      assert Task.plan_safe_category?(:planning)
      refute Task.plan_safe_category?(:acting)
      refute Task.plan_safe_category?(:verifying)
      refute Task.plan_safe_category?(:debugging)
    end

    test "acting_category? is consistent with Policy" do
      assert Task.acting_category?(:acting)
      assert Task.acting_category?(:verifying)
      assert Task.acting_category?(:debugging)
      refute Task.acting_category?(:researching)
      refute Task.acting_category?(:planning)
    end
  end
end
