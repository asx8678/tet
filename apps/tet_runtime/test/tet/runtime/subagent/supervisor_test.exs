defmodule Tet.Runtime.Subagent.SupervisorTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.Subagent.Supervisor
  alias Tet.Subagent.Spec

  setup do
    # Start the Registry without linking so it survives test process exits.
    unless Process.whereis(Tet.Runtime.Subagent.Registry) do
      {:ok, reg_pid} = Registry.start_link(keys: :unique, name: Tet.Runtime.Subagent.Registry)
      Process.unlink(reg_pid)
    end

    # Start the supervisor without linking so it survives the test process exit.
    sup_pid =
      case Process.whereis(Supervisor.name()) do
        nil ->
          {:ok, pid} = Supervisor.start_link([])
          Process.unlink(pid)
          pid

        pid ->
          pid
      end

    # Clean up any leftover subagents from prior test runs
    for %{id: id} <- Supervisor.list_subagents() do
      Supervisor.cancel_subagent(id)
    end

    # Stash original max_workers for restoration
    original_max = Application.get_env(:tet_runtime, :subagent_max_workers)
    Application.put_env(:tet_runtime, :subagent_max_workers, 5)

    on_exit(fn ->
      # Restore original config
      if original_max != nil do
        Application.put_env(:tet_runtime, :subagent_max_workers, original_max)
      else
        Application.delete_env(:tet_runtime, :subagent_max_workers)
      end
    end)

    {:ok, sup: sup_pid}
  end

  defp valid_spec(overrides \\ %{}) do
    attrs =
      %{
        profile_id: "coder",
        parent_task_id: "task_s001"
      }
      |> Map.merge(overrides)

    Spec.new!(attrs)
  end

  describe "start_subagent/1" do
    test "starts a subagent with a valid spec" do
      spec = valid_spec()
      assert {:ok, pid} = Supervisor.start_subagent(spec)
      assert is_pid(pid)
      assert Process.alive?(pid)
    after
      Supervisor.cancel_subagent("sub_task_s001")
    end

    test "returns :already_started for duplicate subagent" do
      spec = valid_spec()
      assert {:ok, _pid} = Supervisor.start_subagent(spec)
      assert {:error, :already_started} = Supervisor.start_subagent(spec)
    after
      Supervisor.cancel_subagent("sub_task_s001")
    end

    test "returns :max_workers_reached when at capacity" do
      test_sup_name = :max_cap_test_sup

      {:ok, sup_pid} =
        DynamicSupervisor.start_link(
          Tet.Runtime.Subagent.Supervisor,
          [max_children: 1],
          name: test_sup_name
        )

      Process.unlink(sup_pid)

      spec1 = valid_spec(%{parent_task_id: "task_cap1"})
      spec2 = valid_spec(%{parent_task_id: "task_cap2"})

      assert {:ok, _pid} =
               DynamicSupervisor.start_child(
                 test_sup_name,
                 {Tet.Runtime.Subagent.Worker, spec1}
               )

      assert {:error, :max_children} =
               DynamicSupervisor.start_child(
                 test_sup_name,
                 {Tet.Runtime.Subagent.Worker, spec2}
               )
    after
      Supervisor.cancel_subagent("sub_task_cap1")
      Supervisor.cancel_subagent("sub_task_cap2")
    end
  end

  describe "list_subagents/0" do
    test "returns running subagents" do
      spec_a = valid_spec(%{parent_task_id: "task_list_a"})
      spec_b = valid_spec(%{parent_task_id: "task_list_b"})

      Supervisor.start_subagent(spec_a)
      Supervisor.start_subagent(spec_b)

      subagents = Supervisor.list_subagents()
      ids = Enum.map(subagents, & &1.id)

      assert "sub_task_list_a" in ids
      assert "sub_task_list_b" in ids
    after
      Supervisor.cancel_subagent("sub_task_list_a")
      Supervisor.cancel_subagent("sub_task_list_b")
    end

    test "returns empty list when no subagents running" do
      assert Supervisor.list_subagents() == []
    end
  end

  describe "list_subagents/1 (by parent task)" do
    test "filters subagents by parent task id" do
      spec_a = valid_spec(%{parent_task_id: "task_filter_a"})
      spec_b = valid_spec(%{parent_task_id: "task_filter_b"})
      spec_c = valid_spec(%{parent_task_id: "task_filter_c"})

      Supervisor.start_subagent(spec_a)
      Supervisor.start_subagent(spec_b)
      Supervisor.start_subagent(spec_c)

      # Should find one subagent for task_filter_a
      results_a = Supervisor.list_subagents("task_filter_a")
      assert length(results_a) == 1

      # Should find one for task_filter_b
      results_b = Supervisor.list_subagents("task_filter_b")
      assert length(results_b) == 1

      # Should find none for unknown task
      results_none = Supervisor.list_subagents("no_such_task")
      assert results_none == []
    after
      Supervisor.cancel_subagent("sub_task_filter_a")
      Supervisor.cancel_subagent("sub_task_filter_b")
      Supervisor.cancel_subagent("sub_task_filter_c")
    end
  end

  describe "cancel_subagent/1" do
    test "cancels a running subagent" do
      spec = valid_spec(%{parent_task_id: "task_cancel1"})
      {:ok, _pid} = Supervisor.start_subagent(spec)

      assert :ok = Supervisor.cancel_subagent("sub_task_cancel1")

      subagents = Supervisor.list_subagents()
      refute Enum.any?(subagents, &(&1.id == "sub_task_cancel1"))
    end

    test "returns error for unknown subagent" do
      assert {:error, :not_found} = Supervisor.cancel_subagent("no_such_subagent")
    end
  end

  describe "cancel_by_task/1" do
    test "cancels all subagents for a task" do
      spec_a = valid_spec(%{parent_task_id: "task_cancel_all"})
      spec_b = valid_spec(%{parent_task_id: "task_other"})

      Supervisor.start_subagent(spec_a)
      Supervisor.start_subagent(spec_b)

      assert :ok = Supervisor.cancel_by_task("task_cancel_all")

      # subagents for task_cancel_all should be gone
      remaining = Supervisor.list_subagents()
      ids = Enum.map(remaining, & &1.id)
      refute "sub_task_cancel_all" in ids
      assert "sub_task_other" in ids
    after
      Supervisor.cancel_subagent("sub_task_cancel_all")
      Supervisor.cancel_subagent("sub_task_other")
    end

    test "is idempotent when no subagents for task" do
      assert :ok = Supervisor.cancel_by_task("non_existent_task")
    end
  end

  describe "count_subagents/0" do
    test "returns zero when no subagents running" do
      assert Supervisor.count_subagents() == 0
    end

    test "returns accurate count" do
      spec_a = valid_spec(%{parent_task_id: "task_count1"})
      spec_b = valid_spec(%{parent_task_id: "task_count2"})

      Supervisor.start_subagent(spec_a)
      assert Supervisor.count_subagents() == 1

      Supervisor.start_subagent(spec_b)
      assert Supervisor.count_subagents() == 2

      Supervisor.cancel_subagent("sub_task_count1")
      assert Supervisor.count_subagents() == 1
    after
      Supervisor.cancel_subagent("sub_task_count1")
      Supervisor.cancel_subagent("sub_task_count2")
    end
  end

  describe "max_workers/0" do
    test "returns configured max workers" do
      Application.put_env(:tet_runtime, :subagent_max_workers, 10)
      assert Supervisor.max_workers() == 10
    end

    test "returns default when not configured" do
      Application.delete_env(:tet_runtime, :subagent_max_workers)
      assert Supervisor.max_workers() == 5
    end
  end
end
