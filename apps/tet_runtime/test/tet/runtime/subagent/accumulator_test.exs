defmodule Tet.Runtime.Subagent.AccumulatorTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Subagent.Accumulator

  describe "start_link/2" do
    test "starts with initial state and default options" do
      {:ok, pid} = Accumulator.start_link(%{output: %{existing: true}})

      assert {:ok, status} = Accumulator.status(pid)
      assert status.collected_count == 0
      assert status.finalized? == false
      assert status.current_state == %{output: %{existing: true}}
    end

    test "starts with custom merge strategy" do
      {:ok, pid} =
        Accumulator.start_link(%{output: %{x: 1}}, merge_strategy: :last_wins)

      assert {:ok, status} = Accumulator.status(pid)
      assert status.merge_strategy == :last_wins
    end
  end

  describe "collect/2 and finalize/1" do
    test "collects results and produces merged output" do
      {:ok, pid} = Accumulator.start_link(%{output: %{existing: true}})

      :ok = Accumulator.collect(pid, %{output: %{new_key: "from_first"}, status: "success"})
      :ok = Accumulator.collect(pid, %{output: %{new_key: "from_second"}, status: "success"})

      assert {:ok, status} = Accumulator.status(pid)
      assert status.collected_count == 2

      assert {:ok, merged} = Accumulator.finalize(pid)
      assert merged.output.existing == true
      # :first_wins — first result's new_key takes precedence
      assert merged.output.new_key == "from_first"
    end

    test "finalize is idempotent" do
      {:ok, pid} = Accumulator.start_link(%{output: %{x: 1}})

      :ok = Accumulator.collect(pid, %{output: %{y: 2}, status: "success"})

      assert {:ok, merged} = Accumulator.finalize(pid)
      assert merged.output.y == 2

      # Second call returns same result
      assert {:ok, merged} = Accumulator.finalize(pid)
      assert merged.output.y == 2
    end

    test "deterministic ordering by metadata.sequence" do
      {:ok, pid} = Accumulator.start_link(%{output: %{}})

      # Add results out of order — they should be sorted by sequence before merging
      :ok =
        Accumulator.collect(pid, %{
          output: %{order: "second"},
          metadata: %{sequence: 2},
          status: "success"
        })

      :ok =
        Accumulator.collect(pid, %{
          output: %{order: "first"},
          metadata: %{sequence: 1},
          status: "success"
        })

      assert {:ok, merged} = Accumulator.finalize(pid)

      # With :first_wins (default), earliest sequence wins
      assert merged.output.order == "first"
    end

    test "deterministic ordering by created_at when no sequence" do
      {:ok, pid} = Accumulator.start_link(%{output: %{}})

      :ok =
        Accumulator.collect(pid, %{
          output: %{val: "later"},
          metadata: %{created_at: 2},
          status: "success"
        })

      :ok =
        Accumulator.collect(pid, %{
          output: %{val: "earlier"},
          metadata: %{created_at: 1},
          status: "success"
        })

      assert {:ok, merged} = Accumulator.finalize(pid)
      assert merged.output.val == "earlier"
    end
  end

  describe "reset/1" do
    test "reset preserves initial state and opts" do
      {:ok, pid} =
        Accumulator.start_link(%{output: %{original: "data"}}, merge_strategy: :last_wins)

      :ok = Accumulator.collect(pid, %{output: %{added: "should_be_cleared"}, status: "success"})

      assert {:ok, status} = Accumulator.status(pid)
      assert status.collected_count == 1

      :ok = Accumulator.reset(pid)

      assert {:ok, status} = Accumulator.status(pid)
      assert status.collected_count == 0
      assert status.finalized? == false
      # Initial state should be preserved, not reset to empty
      assert status.current_state.output.original == "data"
      # Merge strategy should be preserved from opts
      assert status.merge_strategy == :last_wins
    end

    test "reset then collect and finalize works correctly" do
      {:ok, pid} = Accumulator.start_link(%{output: %{base: "value"}})

      :ok = Accumulator.collect(pid, %{output: %{should_be_gone: true}, status: "success"})
      :ok = Accumulator.reset(pid)

      :ok = Accumulator.collect(pid, %{output: %{fresh: "data"}, status: "success"})

      assert {:ok, merged} = Accumulator.finalize(pid)
      assert merged.output.base == "value"
      assert merged.output.fresh == "data"
      refute Map.has_key?(merged.output, :should_be_gone)
    end
  end

  describe "error handling" do
    test "invalid result status causes finalize to return error" do
      {:ok, pid} = Accumulator.start_link(%{output: %{}})

      # Cast with an invalid status should not crash
      :ok = Accumulator.collect(pid, %{output: %{x: 1}, status: "bogus_status"})

      # Should still be alive
      assert Process.alive?(pid)

      # Finalize should return error for invalid status
      assert {:error, {:invalid_status, "bogus_status"}} = Accumulator.finalize(pid)
    end

    test "collect with non-map data does not crash accumulator" do
      {:ok, pid} = Accumulator.start_link(%{output: %{}})

      # Passing something weird shouldn't crash the GenServer
      :ok = Accumulator.collect(pid, %{output: %{x: 1}, status: "success"})

      assert Process.alive?(pid)
      assert {:ok, _merged} = Accumulator.finalize(pid)
    end
  end
end
