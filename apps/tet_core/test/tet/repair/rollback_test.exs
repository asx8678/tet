defmodule Tet.Repair.RollbackTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  alias Tet.Repair.Rollback

  @now ~U[2024-01-02 03:04:05Z]

  describe "new/1" do
    test "builds a valid rollback with minimum attrs" do
      assert {:ok, rollback} =
               Rollback.new(%{
                 id: "rb_001",
                 repair_id: "rep_001"
               })

      assert rollback.id == "rb_001"
      assert rollback.repair_id == "rep_001"
      assert rollback.status == :pending
      assert rollback.patches_reverted == []
      assert rollback.error_log_kept_open == true
      assert rollback.checkpoint_id == nil
      assert rollback.reason == nil
      assert rollback.created_at == nil
      assert rollback.completed_at == nil
    end

    test "builds with all fields" do
      assert {:ok, rollback} =
               Rollback.new(%{
                 id: "rb_full_001",
                 repair_id: "rep_001",
                 checkpoint_id: "cp_001",
                 reason: "compilation error after patch",
                 patches_reverted: ["patch_1", "patch_2"],
                 status: :completed,
                 error_log_kept_open: true,
                 created_at: @now,
                 completed_at: @now
               })

      assert rollback.checkpoint_id == "cp_001"
      assert rollback.reason == "compilation error after patch"
      assert rollback.patches_reverted == ["patch_1", "patch_2"]
      assert rollback.status == :completed
      assert rollback.created_at == @now
      assert rollback.completed_at == @now
    end

    test "accepts all statuses" do
      statuses = [:pending, :in_progress, :completed, :failed]

      for status <- statuses do
        assert {:ok, rollback} =
                 Rollback.new(%{
                   id: "rb_st_#{status}",
                   repair_id: "rep_001",
                   status: status
                 })

        assert rollback.status == status
      end
    end

    test "accepts string keyed attrs" do
      assert {:ok, rollback} =
               Rollback.new(%{
                 "id" => "rb_str_001",
                 "repair_id" => "rep_001",
                 "status" => "in_progress"
               })

      assert rollback.id == "rb_str_001"
      assert rollback.status == :in_progress
    end

    test "rejects missing required fields" do
      assert {:error, {:invalid_entity_field, :rollback, :id}} =
               Rollback.new(%{repair_id: "rep_001"})

      assert {:error, {:invalid_entity_field, :rollback, :repair_id}} =
               Rollback.new(%{id: "rb_001"})
    end

    test "rejects empty string for required binary fields" do
      assert {:error, {:invalid_entity_field, :rollback, :id}} =
               Rollback.new(%{id: "", repair_id: "rep_001"})
    end

    test "rejects invalid status" do
      assert {:error, {:invalid_rollback_field, :status}} =
               Rollback.new(%{id: "rb_001", repair_id: "rep_001", status: :running})
    end

    test "rejects invalid patches_reverted" do
      assert {:error, {:invalid_rollback_field, :patches_reverted}} =
               Rollback.new(%{id: "rb_001", repair_id: "rep_001", patches_reverted: [123]})
    end

    test "rejects non-map" do
      assert {:error, :invalid_rollback} = Rollback.new("not_a_map")
    end
  end

  describe "begin/1" do
    test "transitions pending rollback to in_progress" do
      {:ok, rollback} = Rollback.new(%{id: "rb_001", repair_id: "rep_001"})
      assert {:ok, started} = Rollback.begin(rollback)
      assert started.status == :in_progress
    end

    test "rejects non-pending rollback" do
      {:ok, rollback} =
        Rollback.new(%{id: "rb_001", repair_id: "rep_001", status: :in_progress})

      assert {:error, :not_pending} = Rollback.begin(rollback)
    end

    test "rejects completed rollback" do
      {:ok, rollback} =
        Rollback.new(%{id: "rb_001", repair_id: "rep_001", status: :completed})

      assert {:error, :not_pending} = Rollback.begin(rollback)
    end
  end

  describe "record_revert/2" do
    test "appends patch ID to in-progress rollback" do
      {:ok, rollback} = Rollback.new(%{id: "rb_001", repair_id: "rep_001"})
      {:ok, started} = Rollback.begin(rollback)

      assert {:ok, reverted} = Rollback.record_revert(started, "patch_1")
      assert reverted.patches_reverted == ["patch_1"]

      assert {:ok, reverted2} = Rollback.record_revert(reverted, "patch_2")
      assert reverted2.patches_reverted == ["patch_1", "patch_2"]
    end

    test "rejects pending rollback" do
      {:ok, rollback} = Rollback.new(%{id: "rb_001", repair_id: "rep_001"})
      assert {:error, :not_in_progress} = Rollback.record_revert(rollback, "patch_1")
    end

    test "rejects completed rollback" do
      {:ok, rollback} =
        Rollback.new(%{id: "rb_001", repair_id: "rep_001", status: :completed})

      assert {:error, :not_in_progress} = Rollback.record_revert(rollback, "patch_1")
    end
  end

  describe "complete/1" do
    test "marks in-progress rollback as completed with timestamp" do
      {:ok, rollback} = Rollback.new(%{id: "rb_001", repair_id: "rep_001"})
      {:ok, started} = Rollback.begin(rollback)

      assert {:ok, completed} = Rollback.complete(started)
      assert completed.status == :completed
      assert %DateTime{} = completed.completed_at
    end

    test "rejects pending rollback" do
      {:ok, rollback} = Rollback.new(%{id: "rb_001", repair_id: "rep_001"})
      assert {:error, :not_in_progress} = Rollback.complete(rollback)
    end

    test "rejects already-failed rollback" do
      {:ok, rollback} =
        Rollback.new(%{id: "rb_001", repair_id: "rep_001", status: :failed})

      assert {:error, :not_in_progress} = Rollback.complete(rollback)
    end
  end

  describe "fail/2" do
    test "marks in-progress rollback as failed with reason and timestamp" do
      {:ok, rollback} = Rollback.new(%{id: "rb_001", repair_id: "rep_001"})
      {:ok, started} = Rollback.begin(rollback)

      assert {:ok, failed} = Rollback.fail(started, "disk full")
      assert failed.status == :failed
      assert failed.reason == "disk full"
      assert %DateTime{} = failed.completed_at
    end

    test "rejects pending rollback" do
      {:ok, rollback} = Rollback.new(%{id: "rb_001", repair_id: "rep_001"})
      assert {:error, :not_in_progress} = Rollback.fail(rollback, "reason")
    end

    test "rejects already-completed rollback" do
      {:ok, rollback} =
        Rollback.new(%{id: "rb_001", repair_id: "rep_001", status: :completed})

      assert {:error, :not_in_progress} = Rollback.fail(rollback, "reason")
    end
  end

  describe "keep_error_log_open?/1" do
    test "returns true by default" do
      {:ok, rollback} = Rollback.new(%{id: "rb_001", repair_id: "rep_001"})
      assert Rollback.keep_error_log_open?(rollback) == true
    end

    test "respects explicitly set false" do
      {:ok, rollback} =
        Rollback.new(%{id: "rb_001", repair_id: "rep_001", error_log_kept_open: false})

      assert Rollback.keep_error_log_open?(rollback) == false
    end
  end

  describe "full lifecycle" do
    test "pending → in_progress → record reverts → completed" do
      {:ok, rollback} =
        Rollback.new(%{
          id: "rb_life_001",
          repair_id: "rep_001",
          checkpoint_id: "cp_001",
          reason: "compile error after patch"
        })

      assert rollback.status == :pending

      {:ok, started} = Rollback.begin(rollback)
      assert started.status == :in_progress

      {:ok, r1} = Rollback.record_revert(started, "patch_a")
      {:ok, r2} = Rollback.record_revert(r1, "patch_b")
      assert r2.patches_reverted == ["patch_a", "patch_b"]

      {:ok, done} = Rollback.complete(r2)
      assert done.status == :completed
      assert Rollback.keep_error_log_open?(done) == true
    end

    test "pending → in_progress → failed" do
      {:ok, rollback} = Rollback.new(%{id: "rb_life_002", repair_id: "rep_002"})
      {:ok, started} = Rollback.begin(rollback)
      {:ok, failed} = Rollback.fail(started, "could not revert: permission denied")

      assert failed.status == :failed
      assert failed.reason == "could not revert: permission denied"
    end
  end

  describe "to_map/1 and from_map/1 round-trip" do
    test "round-trips all fields" do
      attrs = %{
        id: "rb_rt_001",
        repair_id: "rep_001",
        checkpoint_id: "cp_001",
        reason: "test reason",
        patches_reverted: ["p1", "p2"],
        status: :completed,
        error_log_kept_open: true,
        created_at: @now,
        completed_at: @now
      }

      assert {:ok, rollback} = Rollback.new(attrs)
      map = Rollback.to_map(rollback)
      assert {:ok, ^rollback} = Rollback.from_map(map)
    end

    test "round-trips minimal rollback" do
      attrs = %{id: "rb_rt_min", repair_id: "rep_002"}

      assert {:ok, rollback} = Rollback.new(attrs)
      map = Rollback.to_map(rollback)
      assert {:ok, ^rollback} = Rollback.from_map(map)
    end
  end

  describe "statuses/0" do
    test "returns all valid statuses" do
      assert Rollback.statuses() == [:pending, :in_progress, :completed, :failed]
    end
  end
end
