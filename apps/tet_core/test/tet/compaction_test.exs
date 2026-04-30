defmodule Tet.CompactionTest do
  use ExUnit.Case, async: true

  test "small contexts are no-ops but still report summary metadata" do
    messages = [message("sys", :system), message("u1", :user), message("a1", :assistant)]

    assert {:ok, result} = Tet.Compaction.compact(messages, max_messages: 10, recent_count: 2)

    refute result.changed?
    assert result.id == nil
    assert result.summary == nil
    assert result.messages == messages
    assert result.retained_messages == messages
    assert result.compacted_messages == []
    assert result.compactions == []

    assert result.metadata["contract_version"] == Tet.Compaction.version()
    assert result.metadata["original_message_count"] == 3
    assert result.metadata["retained_message_count"] == 3
    assert result.metadata["compacted_message_count"] == 0
    assert result.metadata["noop_reason"] == "below_max_messages"
    assert result.metadata["compacted_range"] == nil

    assert result.metadata["options"] == %{
             "force" => false,
             "max_messages" => 10,
             "min_compacted_count" => 1,
             "recent_count" => 2
           }
  end

  test "protects leading system prompt and configurable recent-message window" do
    messages = [
      message("sys", :system),
      message("u1", :user),
      message("a1", :assistant),
      message("u2", :user),
      message("a2", :assistant),
      message("u3", :user),
      message("a3", :assistant)
    ]

    assert {:ok, result} = Tet.Compaction.compact(messages, max_messages: 3, recent_count: 2)

    assert result.changed?
    assert Enum.map(result.compacted_messages, & &1.id) == ["u1", "a1", "u2", "a2"]
    assert Enum.map(Tet.Compaction.to_prompt_messages(result), & &1.id) == ["sys", "u3", "a3"]

    assert Enum.map(Tet.Compaction.to_provider_messages(result), & &1.role) == [
             :system,
             :system,
             :user,
             :assistant
           ]

    [compaction] = Tet.Compaction.to_prompt_compactions(result)
    assert compaction.source_message_ids == ["u1", "a1", "u2", "a2"]
    assert compaction.original_message_count == 7
    assert compaction.retained_message_count == 3
    assert compaction.strategy == "deterministic_summary"

    assert result.metadata["original_range"] == %{
             "first_index" => 0,
             "first_message_id" => "sys",
             "last_index" => 6,
             "last_message_id" => "a3"
           }

    assert result.metadata["compacted_range"] == %{
             "first_index" => 1,
             "first_message_id" => "u1",
             "last_index" => 4,
             "last_message_id" => "a2"
           }

    assert result.metadata["protected"] == %{
             "adjusted_recent_start_index" => 5,
             "leading_system_count" => 1,
             "requested_recent_count" => 2,
             "requested_recent_start_index" => 5
           }
  end

  test "moves split backward instead of severing a protected tool call/result pair" do
    messages = [
      message("sys", :system),
      message("u1", :user),
      tool_call_message("call-msg", "call-1"),
      tool_result_message("result-msg", "call-1"),
      message("u2", :user),
      message("a2", :assistant)
    ]

    assert {:ok, result} = Tet.Compaction.compact(messages, force: true, recent_count: 3)

    assert result.changed?
    assert Enum.map(result.compacted_messages, & &1.id) == ["u1"]

    assert Enum.map(result.retained_messages, & &1.id) == [
             "sys",
             "call-msg",
             "result-msg",
             "u2",
             "a2"
           ]

    [protected_pair] = result.metadata["protected_tool_pairs"]

    assert protected_pair == %{
             "call_indexes" => [2],
             "call_message_ids" => ["call-msg"],
             "location" => "retained",
             "reason" => "split_boundary",
             "result_indexes" => [3],
             "result_message_ids" => ["result-msg"],
             "tool_call_id" => "call-1"
           }

    assert result.metadata["protected"]["requested_recent_start_index"] == 3
    assert result.metadata["protected"]["adjusted_recent_start_index"] == 2
  end

  test "does not sever a tool pair split between the protected system head and compacted range" do
    messages = [
      tool_call_message("sys-call", :system, "call-head"),
      message("sys-policy", :system),
      tool_result_message("head-result", "call-head"),
      message("u1", :user),
      message("a1", :assistant),
      message("u2", :user),
      message("a2", :assistant)
    ]

    assert {:ok, result} = Tet.Compaction.compact(messages, force: true, recent_count: 2)

    refute result.changed?
    assert result.compacted_messages == []
    assert Enum.map(result.retained_messages, & &1.id) == Enum.map(messages, & &1.id)

    [protected_pair] = result.metadata["protected_tool_pairs"]

    assert protected_pair == %{
             "call_indexes" => [0],
             "call_message_ids" => ["sys-call"],
             "location" => "retained",
             "reason" => "split_boundary",
             "result_indexes" => [2],
             "result_message_ids" => ["head-result"],
             "tool_call_id" => "call-head"
           }

    assert result.metadata["noop_reason"] == "nothing_to_compact"
    assert result.metadata["protected"]["leading_system_count"] == 2
    assert result.metadata["protected"]["requested_recent_start_index"] == 5
    assert result.metadata["protected"]["adjusted_recent_start_index"] == 2
  end

  test "keeps older tool call/result pairs atomic inside the compacted side" do
    messages = [
      message("sys", :system),
      message("u1", :user),
      tool_call_message("call-msg", "call-2"),
      tool_result_message("result-msg", "call-2"),
      message("mid", :assistant),
      message("u2", :user),
      message("a2", :assistant)
    ]

    assert {:ok, result} = Tet.Compaction.compact(messages, force: true, recent_count: 2)

    assert Enum.map(result.compacted_messages, & &1.id) == [
             "u1",
             "call-msg",
             "result-msg",
             "mid"
           ]

    assert Enum.map(result.retained_messages, & &1.id) == ["sys", "u2", "a2"]
    assert result.metadata["protected_tool_pairs"] == []

    [pair] = result.metadata["tool_pairs"]
    assert pair["tool_call_id"] == "call-2"
    assert pair["location"] == "compacted"
    assert pair["call_message_ids"] == ["call-msg"]
    assert pair["result_message_ids"] == ["result-msg"]
  end

  test "compaction output is deterministic and carries prompt-layer metadata" do
    messages = [
      message("sys", :system),
      message("u1", :user),
      message("a1", :assistant),
      message("u2", :user),
      message("a2", :assistant)
    ]

    opts = [force: true, recent_count: 2, strategy: :summary_artifact]

    assert {:ok, first} = Tet.Compaction.compact(messages, opts)
    assert {:ok, second} = Tet.Compaction.compact(messages, opts)

    assert first.id == second.id
    assert first.summary == second.summary
    assert first.metadata == second.metadata
    assert first.compactions == second.compactions

    [compaction] = first.compactions
    assert compaction.id == first.id
    assert compaction.summary == first.summary
    assert compaction.strategy == "summary_artifact"
    assert compaction.source_message_ids == ["u1", "a1"]
    assert compaction.metadata["original_message_count"] == 5
    assert compaction.metadata["retained_message_count"] == 3
    assert compaction.metadata["compacted_message_count"] == 2
    assert compaction.metadata["options"]["recent_count"] == 2
  end

  defp tool_call_message(id, tool_call_id) do
    tool_call_message(id, :assistant, tool_call_id)
  end

  defp tool_call_message(id, role, tool_call_id) do
    message(id, role, "calling #{tool_call_id}", %{
      tool_calls: [%{id: tool_call_id, name: "read_file"}]
    })
  end

  defp tool_result_message(id, tool_call_id) do
    message(id, :tool, "result #{tool_call_id}", %{tool_call_id: tool_call_id})
  end

  defp message(id, role, content \\ nil, metadata \\ %{}) do
    %Tet.Message{
      id: id,
      session_id: "session-compaction",
      role: role,
      content: content || "content #{id}",
      timestamp: "2025-01-01T00:00:00.000Z",
      metadata: metadata
    }
  end
end
