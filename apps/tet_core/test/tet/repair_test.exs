defmodule Tet.RepairTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  @now ~U[2024-01-02 03:04:05Z]
  @later ~U[2024-01-02 03:05:06Z]

  describe "new/1" do
    test "builds a valid repair entry with minimum attrs" do
      assert {:ok, repair} =
               Tet.Repair.new(%{
                 id: "rep_min_001",
                 error_log_id: "err_001",
                 strategy: :retry
               })

      assert repair.id == "rep_min_001"
      assert repair.error_log_id == "err_001"
      assert repair.strategy == :retry
      assert repair.status == :pending
      assert repair.params == nil
      assert repair.result == nil
      assert repair.metadata == %{}
    end

    test "accepts all strategies" do
      strategies = [:retry, :fallback, :patch, :human]

      for strategy <- strategies do
        assert {:ok, repair} =
                 Tet.Repair.new(%{
                   id: "rep_#{strategy}",
                   error_log_id: "err_001",
                   strategy: strategy
                 })

        assert repair.strategy == strategy
      end
    end

    test "accepts all statuses" do
      statuses = [:pending, :running, :succeeded, :failed, :skipped]

      for status <- statuses do
        assert {:ok, repair} =
                 Tet.Repair.new(%{
                   id: "rep_st_#{status}",
                   error_log_id: "err_001",
                   strategy: :retry,
                   status: status
                 })

        assert repair.status == status
      end
    end

    test "accepts string keyed attrs" do
      assert {:ok, repair} =
               Tet.Repair.new(%{
                 "id" => "rep_str_001",
                 "error_log_id" => "err_001",
                 "strategy" => "retry"
               })

      assert repair.id == "rep_str_001"
      assert repair.strategy == :retry
    end

    test "accepts full set of fields" do
      assert {:ok, repair} =
               Tet.Repair.new(%{
                 id: "rep_full_001",
                 error_log_id: "err_001",
                 session_id: "ses_test",
                 strategy: :patch,
                 params: %{file: "lib/bug.ex", replacement: "fix"},
                 result: %{patched: true},
                 status: :succeeded,
                 created_at: @now,
                 started_at: @now,
                 completed_at: @later,
                 metadata: %{"source" => "auto"}
               })

      assert repair.id == "rep_full_001"
      assert repair.error_log_id == "err_001"
      assert repair.session_id == "ses_test"
      assert repair.strategy == :patch
      assert repair.params == %{file: "lib/bug.ex", replacement: "fix"}
      assert repair.result == %{patched: true}
      assert repair.status == :succeeded
      assert repair.created_at == @now
      assert repair.started_at == @now
      assert repair.completed_at == @later
      assert repair.metadata == %{"source" => "auto"}
    end

    test "rejects invalid strategy" do
      assert {:error, {:invalid_repair_field, :strategy}} =
               Tet.Repair.new(%{
                 id: "rep_bad",
                 error_log_id: "err_001",
                 strategy: :rollback
               })
    end

    test "rejects invalid status" do
      assert {:error, {:invalid_repair_field, :status}} =
               Tet.Repair.new(%{
                 id: "rep_bad_st",
                 error_log_id: "err_001",
                 strategy: :retry,
                 status: :in_progress
               })
    end

    test "rejects missing required fields" do
      assert {:error, {:invalid_entity_field, :repair, :id}} =
               Tet.Repair.new(%{error_log_id: "err_001", strategy: :retry})

      assert {:error, {:invalid_entity_field, :repair, :error_log_id}} =
               Tet.Repair.new(%{id: "rep_001", strategy: :retry})

      assert {:error, {:invalid_repair_field, :strategy}} =
               Tet.Repair.new(%{id: "rep_001", error_log_id: "err_001"})
    end

    test "rejects empty string for required binary fields" do
      assert {:error, {:invalid_entity_field, :repair, :id}} =
               Tet.Repair.new(%{id: "", error_log_id: "err_001", strategy: :retry})
    end
  end

  describe "to_map/1 and from_map/1 round-trip" do
    test "round-trips all fields" do
      attrs = %{
        id: "rep_rt_001",
        error_log_id: "err_001",
        session_id: "ses_test",
        strategy: :fallback,
        params: %{timeout: 5000},
        result: nil,
        status: :pending,
        created_at: @now,
        started_at: nil,
        completed_at: nil,
        metadata: %{"origin" => "test"}
      }

      assert {:ok, repair} = Tet.Repair.new(attrs)
      map = Tet.Repair.to_map(repair)
      assert {:ok, ^repair} = Tet.Repair.from_map(map)
    end

    test "round-trips succeeded repair" do
      attrs = %{
        id: "rep_rt_succ",
        error_log_id: "err_002",
        session_id: "ses_test",
        strategy: :retry,
        params: %{attempt: 2},
        result: %{success: true},
        status: :succeeded,
        created_at: @now,
        started_at: @now,
        completed_at: @later
      }

      assert {:ok, repair} = Tet.Repair.new(attrs)
      map = Tet.Repair.to_map(repair)
      assert {:ok, ^repair} = Tet.Repair.from_map(map)
    end
  end

  describe "statuses/0" do
    test "returns all valid statuses" do
      assert Tet.Repair.statuses() == [:pending, :running, :succeeded, :failed, :skipped]
    end
  end

  describe "terminal_statuses/0" do
    test "returns terminal statuses" do
      assert Tet.Repair.terminal_statuses() == [:succeeded, :failed, :skipped]
    end
  end
end
