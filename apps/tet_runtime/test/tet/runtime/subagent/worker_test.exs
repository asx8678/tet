defmodule Tet.Runtime.Subagent.WorkerTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Subagent.Worker
  alias Tet.Subagent.Spec

  setup do
    # Start the Registry without linking so it survives test process exits
    # in async mode.
    unless Process.whereis(Tet.Runtime.Subagent.Registry) do
      {:ok, reg_pid} = Registry.start_link(keys: :unique, name: Tet.Runtime.Subagent.Registry)
      Process.unlink(reg_pid)
    end

    :ok
  end

  defp valid_spec(overrides \\ %{}) do
    attrs =
      %{
        profile_id: "coder",
        # Use a unique parent_task_id per call so async tests don't collide
        # in the shared Registry.
        parent_task_id: "task_w#{System.unique_integer([:positive])}"
      }
      |> Map.merge(overrides)

    Spec.new!(attrs)
  end

  describe "start_link/1" do
    test "starts a worker with a valid spec" do
      spec = valid_spec()
      assert {:ok, pid} = Worker.start_link(spec)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "stores spec accessible via get_spec/1" do
      spec = valid_spec()
      {:ok, pid} = Worker.start_link(spec)
      assert Worker.get_spec(pid) == spec
    end

    test "starts in :idle status" do
      {:ok, pid} = Worker.start_link(valid_spec())
      assert Worker.get_status(pid) == :idle
    end
  end

  describe "start_run/1" do
    test "transitions from :idle to :running" do
      {:ok, pid} = Worker.start_link(valid_spec())
      assert {:ok, ^pid} = Worker.start_run(pid)
      assert Worker.get_status(pid) == :running
    end

    test "fails if already cancelled" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.cancel(pid)
      assert {:error, {:cancelled, _}} = Worker.start_run(pid)
    end

    test "fails if already completed" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      Worker.complete(pid)
      assert {:error, :not_found} = Worker.start_run(pid)
    end

    test "fails if already errored" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      Worker.error(pid, "something broke")
      assert {:error, :not_found} = Worker.start_run(pid)
    end
  end

  describe "complete/1" do
    test "transitions from :running to :completed and stops" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      assert {:ok, :completed} = Worker.complete(pid)
      refute Process.alive?(pid)
    end

    test "succeeds from :cancelled (idempotent terminal)" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.cancel(pid)
      assert {:ok, :cancelled} = Worker.complete(pid)
    end

    test "returns not_found from completed (process stopped)" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      Worker.complete(pid)
      assert {:error, :not_found} = Worker.complete(pid)
    end

    test "returns not_found from error (process stopped)" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      Worker.error(pid)
      assert {:error, :not_found} = Worker.complete(pid)
    end
  end

  describe "error/1,2" do
    test "transitions from :running to :error and stops" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      assert {:ok, :error} = Worker.error(pid, "timeout")
      refute Process.alive?(pid)
    end

    test "succeeds from :cancelled" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.cancel(pid)
      assert {:ok, :cancelled} = Worker.error(pid)
    end

    test "returns not_found from completed (process stopped)" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      Worker.complete(pid)
      assert {:error, :not_found} = Worker.error(pid)
    end

    test "returns not_found from error (process stopped)" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      Worker.error(pid)
      assert {:error, :not_found} = Worker.error(pid)
    end
  end

  describe "cancel/1" do
    test "cancels from :idle" do
      {:ok, pid} = Worker.start_link(valid_spec())
      assert {:ok, :cancelled} = Worker.cancel(pid)
      assert Worker.get_status(pid) == :cancelled
    end

    test "cancels from :running" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      assert {:ok, :cancelled} = Worker.cancel(pid)
      assert Worker.get_status(pid) == :cancelled
    end

    test "is idempotent on :cancelled" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.cancel(pid)
      assert {:ok, :cancelled} = Worker.cancel(pid)
    end

    test "returns not_found from completed (process stopped)" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      Worker.complete(pid)
      assert {:error, :not_found} = Worker.cancel(pid)
    end

    test "returns not_found from error (process stopped)" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      Worker.error(pid)
      assert {:error, :not_found} = Worker.cancel(pid)
    end
  end

  describe "budget tracking" do
    test "budget_remaining returns nil when no budget set" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      assert Worker.budget_remaining(pid) == nil
    end

    test "budget_remaining returns full budget initially" do
      {:ok, pid} = Worker.start_link(valid_spec(%{budget: 100_000}))
      assert Worker.budget_remaining(pid) == 100_000
    end

    test "record_cost deducts from budget" do
      {:ok, pid} = Worker.start_link(valid_spec(%{budget: 100_000}))
      assert {:ok, 80_000} = Worker.record_cost(pid, 20_000)
      assert Worker.budget_remaining(pid) == 80_000
    end

    test "record_cost returns :over_budget when limit exceeded" do
      {:ok, pid} = Worker.start_link(valid_spec(%{budget: 10_000}))
      assert {:error, :over_budget} = Worker.record_cost(pid, 15_000)
      # Budget is NOT consumed on over_budget
      assert Worker.budget_remaining(pid) == 10_000
    end

    test "record_cost without budget returns ok with nil" do
      {:ok, pid} = Worker.start_link(valid_spec())
      assert {:ok, nil} = Worker.record_cost(pid, 5_000)
    end

    test "multiple cost recordings accumulate" do
      {:ok, pid} = Worker.start_link(valid_spec(%{budget: 100_000}))
      {:ok, 90_000} = Worker.record_cost(pid, 10_000)
      {:ok, 70_000} = Worker.record_cost(pid, 20_000)
      assert Worker.budget_remaining(pid) == 70_000
    end

    test "budget_remaining returns 0 when entirely consumed" do
      {:ok, pid} = Worker.start_link(valid_spec(%{budget: 50_000}))
      {:ok, 0} = Worker.record_cost(pid, 50_000)
      assert Worker.budget_remaining(pid) == 0
    end
  end

  describe "timeout enforcement" do
    test "triggers error when timeout expires" do
      {:ok, pid} = Worker.start_link(valid_spec(%{timeout: 10}))
      Worker.start_run(pid)
      assert Worker.get_status(pid) == :running

      # Wait for timeout to fire
      :timer.sleep(30)

      refute Process.alive?(pid)
    end

    test "cancels timer on complete before timeout" do
      {:ok, pid} = Worker.start_link(valid_spec(%{timeout: 100}))
      Worker.start_run(pid)
      Worker.complete(pid)

      # Process stopped, so timer was cancelled
      refute Process.alive?(pid)
    end

    test "cancels timer on error before timeout" do
      {:ok, pid} = Worker.start_link(valid_spec(%{timeout: 100}))
      Worker.start_run(pid)
      Worker.error(pid, "manual")

      refute Process.alive?(pid)
    end

    test "cancels timer on cancel before timeout" do
      {:ok, pid} = Worker.start_link(valid_spec(%{timeout: 100}))
      Worker.start_run(pid)
      Worker.cancel(pid)
      assert Worker.get_status(pid) == :cancelled

      # Give the timer time to fire (it shouldn't)
      :timer.sleep(50)
      assert Worker.get_status(pid) == :cancelled
    end

    test "no timeout set does not auto-timeout" do
      {:ok, pid} = Worker.start_link(valid_spec())
      Worker.start_run(pid)
      assert Worker.get_status(pid) == :running

      :timer.sleep(30)
      assert Worker.get_status(pid) == :running

      Worker.cancel(pid)
    end
  end

  describe "get_spec/1" do
    test "returns nil for dead pid" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)
      Process.exit(pid, :kill)
      :timer.sleep(10)
      assert Worker.get_spec(pid) == nil
    end
  end

  describe "get_status/1" do
    test "returns nil for dead pid" do
      pid = spawn(fn -> :timer.sleep(:infinity) end)
      Process.exit(pid, :kill)
      :timer.sleep(10)
      assert Worker.get_status(pid) == nil
    end
  end
end
