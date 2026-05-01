defmodule Tet.Approval.BlockedActionTest do
  @moduledoc """
  BD-0027: BlockedAction record struct tests.

  Covers construction, validation, gate-decision builder,
  serialization round-trips, and correlation metadata.
  """

  use ExUnit.Case, async: true

  alias Tet.Approval.BlockedAction

  describe "new/1" do
    test "builds a valid blocked-action from required attrs" do
      attrs = %{
        id: "blk_001",
        tool_name: "write-file",
        reason: :plan_mode_blocks_mutation,
        tool_call_id: "call_abc"
      }

      assert {:ok, record} = BlockedAction.new(attrs)
      assert record.id == "blk_001"
      assert record.tool_name == "write-file"
      assert record.reason == :plan_mode_blocks_mutation
      assert record.tool_call_id == "call_abc"
      assert record.args_summary == nil
      assert record.metadata == %{}
    end

    test "builds blocked-action with all optional attrs" do
      now = DateTime.utc_now()

      attrs = %{
        id: "blk_002",
        tool_name: "shell",
        reason: :no_active_task,
        tool_call_id: "call_xyz",
        args_summary: %{command: "rm -rf /", cwd: "/workspace"},
        timestamp: now,
        session_id: "ses_001",
        task_id: "task_001",
        metadata: %{mutation: :execute}
      }

      assert {:ok, record} = BlockedAction.new(attrs)
      assert record.args_summary == %{command: "rm -rf /", cwd: "/workspace"}
      assert record.timestamp == now
      assert record.session_id == "ses_001"
      assert record.task_id == "task_001"
    end

    test "accepts string reason via parsing" do
      attrs = %{
        id: "blk_003",
        tool_name: "shell",
        reason: "category_blocks_tool",
        tool_call_id: "call_1"
      }

      assert {:ok, record} = BlockedAction.new(attrs)
      assert record.reason == :category_blocks_tool
    end

    test "rejects missing id" do
      assert {:error, {:invalid_blocked_action_field, :id}} =
               BlockedAction.new(%{tool_name: "t", reason: :no_active_task, tool_call_id: "c"})
    end

    test "rejects missing tool_name" do
      assert {:error, {:invalid_blocked_action_field, :tool_name}} =
               BlockedAction.new(%{id: "b1", reason: :no_active_task, tool_call_id: "c"})
    end

    test "rejects missing reason" do
      assert {:error, {:invalid_blocked_action_field, :reason}} =
               BlockedAction.new(%{id: "b1", tool_name: "t", tool_call_id: "c"})
    end

    test "rejects missing tool_call_id" do
      assert {:error, {:invalid_blocked_action_field, :tool_call_id}} =
               BlockedAction.new(%{id: "b1", tool_name: "t", reason: :no_active_task})
    end

    test "rejects non-map args_summary" do
      assert {:error, {:invalid_blocked_action_field, :args_summary}} =
               BlockedAction.new(%{
                 id: "b1",
                 tool_name: "t",
                 reason: :no_active_task,
                 tool_call_id: "c",
                 args_summary: "not a map"
               })
    end

    test "accepts nil args_summary" do
      attrs = %{
        id: "b1",
        tool_name: "t",
        reason: :no_active_task,
        tool_call_id: "c",
        args_summary: nil
      }

      assert {:ok, record} = BlockedAction.new(attrs)
      assert record.args_summary == nil
    end

    test "accepts string-keyed attrs" do
      attrs = %{
        "id" => "blk_str",
        "tool_name" => "write-file",
        "reason" => "plan_mode_blocks_mutation",
        "tool_call_id" => "call_str"
      }

      assert {:ok, record} = BlockedAction.new(attrs)
      assert record.id == "blk_str"
    end
  end

  describe "new!/1" do
    test "builds or raises" do
      attrs = %{id: "b1", tool_name: "t", reason: :no_active_task, tool_call_id: "c"}
      assert %BlockedAction{} = BlockedAction.new!(attrs)
    end

    test "raises on invalid attrs" do
      assert_raise ArgumentError, fn -> BlockedAction.new!(%{id: ""}) end
    end
  end

  describe "from_gate_decision/2" do
    test "builds blocked-action from gate block decision" do
      attrs = %{
        id: "blk_gate",
        tool_name: "write-file",
        tool_call_id: "call_gate",
        session_id: "ses_gate",
        task_id: "task_gate"
      }

      assert {:ok, record} =
               BlockedAction.from_gate_decision(attrs, {:block, :plan_mode_blocks_mutation})

      assert record.reason == :plan_mode_blocks_mutation
      assert record.tool_name == "write-file"
      assert record.session_id == "ses_gate"
    end

    test "rejects non-block decisions" do
      assert {:error, {:not_a_block_decision, nil}} =
               BlockedAction.from_gate_decision(%{}, :allow)
    end

    test "rejects guide decisions" do
      assert {:error, {:not_a_block_decision, nil}} =
               BlockedAction.from_gate_decision(%{}, {:guide, "hint"})
    end
  end

  describe "to_map/1 and from_map/1 round-trip" do
    test "round-trips a blocked-action record" do
      record =
        BlockedAction.new!(%{
          id: "blk_rt",
          tool_name: "shell",
          reason: :no_active_task,
          tool_call_id: "call_rt",
          session_id: "ses_rt",
          task_id: "task_rt",
          args_summary: %{command: "ls"},
          metadata: %{risk: :high}
        })

      map = BlockedAction.to_map(record)
      assert map.id == "blk_rt"
      assert map.tool_name == "shell"
      assert map.reason == "no_active_task"
      assert map.args_summary == %{command: "ls"}

      assert {:ok, restored} = BlockedAction.from_map(map)
      assert restored.id == record.id
      assert restored.tool_name == record.tool_name
      assert restored.reason == record.reason
      assert restored.session_id == record.session_id
    end
  end

  describe "known_block_reasons/0" do
    test "includes standard gate block reasons" do
      reasons = BlockedAction.known_block_reasons()
      assert :no_active_task in reasons
      assert :plan_mode_blocks_mutation in reasons
      assert :category_blocks_tool in reasons
      assert :mode_not_allowed in reasons
    end
  end
end
