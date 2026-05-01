defmodule Tet.Patch.ResultTest do
  use ExUnit.Case, async: true

  alias Tet.Patch.{Result, Snapshot}

  describe "success/1" do
    test "creates a success result" do
      result = Result.success(tool_call_id: "call_123")

      assert result.ok == true
      assert result.tool_call_id == "call_123"
      assert result.applied == []
      assert result.pre_snapshots == []
      assert result.post_snapshots == []
      assert result.rolled_back == false
      assert result.error == nil
    end

    test "includes all optional fields" do
      pre_snap = Snapshot.pre_apply("lib/a.ex", "old")
      post_snap = Snapshot.post_apply("lib/a.ex", "new")

      result =
        Result.success(
          tool_call_id: "call_1",
          task_id: "task_1",
          approval_id: "appr_1",
          applied: [%{kind: :modify, file_path: "lib/a.ex"}],
          pre_snapshots: [pre_snap],
          post_snapshots: [post_snap],
          verifier_output: %{exit_code: 0},
          rolled_back: false
        )

      assert result.ok == true
      assert result.task_id == "task_1"
      assert result.approval_id == "appr_1"
      assert length(result.applied) == 1
      assert length(result.pre_snapshots) == 1
      assert result.verifier_output == %{exit_code: 0}
    end
  end

  describe "error/1" do
    test "creates an error result" do
      result = Result.error(tool_call_id: "call_123", error: "Something failed")

      assert result.ok == false
      assert result.tool_call_id == "call_123"
      assert result.error == "Something failed"
    end

    test "includes rollback info when present" do
      result =
        Result.error(
          tool_call_id: "call_1",
          error: "Verifier failed",
          rolled_back: true,
          rollback_output: %{restored: ["lib/a.ex"]}
        )

      assert result.ok == false
      assert result.rolled_back == true
      assert result.rollback_output == %{restored: ["lib/a.ex"]}
    end

    test "has default error message" do
      result = Result.error(tool_call_id: "call_1")
      assert result.error == "Unknown error"
    end
  end

  describe "to_map/1" do
    test "converts success result to map" do
      result = Result.success(tool_call_id: "call_1", applied: [%{kind: :create}])
      map = Result.to_map(result)

      assert map["ok"] == true
      assert map["tool_call_id"] == "call_1"
      assert map["applied"] == [%{kind: :create}]
    end

    test "converts error result to map" do
      result = Result.error(tool_call_id: "call_1", error: "fail")
      map = Result.to_map(result)

      assert map["ok"] == false
      assert map["error"] == "fail"
    end
  end
end
