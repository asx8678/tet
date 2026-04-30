defmodule Tet.Compaction.ToolPairs do
  @moduledoc false

  @scalar_tool_id_keys [
    :tool_call_id,
    "tool_call_id",
    :toolCallId,
    "toolCallId",
    :call_id,
    "call_id"
  ]
  @tool_call_collection_keys [:tool_calls, "tool_calls", :tool_call, "tool_call"]
  @tool_result_collection_keys [:tool_results, "tool_results", :tool_result, "tool_result"]
  @nested_tool_id_keys [:id, "id" | @scalar_tool_id_keys]

  @type occurrence :: %{required(:index) => non_neg_integer(), required(:message_id) => binary()}
  @type pair :: %{
          required(:tool_call_id) => binary(),
          required(:call_indexes) => [non_neg_integer()],
          required(:call_message_ids) => [binary()],
          required(:result_indexes) => [non_neg_integer()],
          required(:result_message_ids) => [binary()],
          required(:indexes) => [non_neg_integer()]
        }
  @type orphan :: %{
          required(:tool_call_id) => binary(),
          required(:indexes) => [non_neg_integer()],
          required(:message_ids) => [binary()]
        }
  @type index :: %{
          required(:pairs) => [pair()],
          required(:orphaned_calls) => [orphan()],
          required(:orphaned_results) => [orphan()]
        }

  @doc "Indexes complete and orphaned tool-call/result pairs in message order."
  @spec index([Tet.Message.t()]) :: index()
  def index(messages) when is_list(messages) do
    calls = tool_occurrences(messages, :call)
    results = tool_occurrences(messages, :result)
    call_ids = Map.keys(calls)
    result_ids = Map.keys(results)

    pairs =
      call_ids
      |> Enum.filter(&Map.has_key?(results, &1))
      |> Enum.map(&pair(&1, Map.fetch!(calls, &1), Map.fetch!(results, &1)))
      |> Enum.sort_by(&min_index/1)

    %{
      pairs: pairs,
      orphaned_calls: orphaned(calls, result_ids),
      orphaned_results: orphaned(results, call_ids)
    }
  end

  @doc "Returns the first message index touched by a pair."
  @spec min_index(pair()) :: non_neg_integer()
  def min_index(pair), do: pair.indexes |> List.first() |> Kernel.||(0)

  defp tool_occurrences(messages, kind) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {message, index}, acc ->
      message
      |> tool_ids(kind)
      |> Enum.reduce(acc, fn tool_call_id, inner_acc ->
        occurrence = %{index: index, message_id: message.id}
        Map.update(inner_acc, tool_call_id, [occurrence], &[occurrence | &1])
      end)
    end)
  end

  defp tool_ids(%Tet.Message{role: :tool, metadata: metadata}, :result) do
    metadata
    |> collect_scalar_tool_ids()
    |> Kernel.++(collect_collection_tool_ids(metadata, @tool_result_collection_keys))
    |> unique_strings()
  end

  defp tool_ids(%Tet.Message{metadata: metadata}, :result) do
    metadata
    |> collect_collection_tool_ids(@tool_result_collection_keys)
    |> unique_strings()
  end

  defp tool_ids(%Tet.Message{role: :tool}, :call), do: []

  defp tool_ids(%Tet.Message{metadata: metadata}, :call) do
    metadata
    |> collect_scalar_tool_ids()
    |> Kernel.++(collect_collection_tool_ids(metadata, @tool_call_collection_keys))
    |> unique_strings()
  end

  defp collect_scalar_tool_ids(metadata) do
    metadata
    |> collect_values(@scalar_tool_id_keys)
    |> unique_strings()
  end

  defp collect_collection_tool_ids(metadata, keys) do
    metadata
    |> collect_values(keys)
    |> Enum.flat_map(&nested_tool_ids/1)
  end

  defp collect_values(metadata, keys) when is_map(metadata) do
    Enum.flat_map(keys, fn key -> metadata |> Map.get(key) |> values_to_list() end)
  end

  defp values_to_list(nil), do: []
  defp values_to_list(value) when is_binary(value) and value != "", do: [value]
  defp values_to_list(values) when is_list(values), do: values
  defp values_to_list(value) when is_map(value), do: [value]
  defp values_to_list(_value), do: []

  defp nested_tool_ids(value) when is_binary(value) and value != "", do: [value]

  defp nested_tool_ids(value) when is_map(value) do
    collect_values(value, @nested_tool_id_keys)
  end

  defp nested_tool_ids(_value), do: []

  defp pair(tool_call_id, call_occurrences, result_occurrences) do
    call_occurrences = Enum.sort_by(call_occurrences, & &1.index)
    result_occurrences = Enum.sort_by(result_occurrences, & &1.index)

    call_indexes = occurrences_indexes(call_occurrences)
    result_indexes = occurrences_indexes(result_occurrences)

    %{
      tool_call_id: tool_call_id,
      call_indexes: call_indexes,
      call_message_ids: occurrence_message_ids(call_occurrences),
      result_indexes: result_indexes,
      result_message_ids: occurrence_message_ids(result_occurrences),
      indexes: Enum.sort(Enum.uniq(call_indexes ++ result_indexes))
    }
  end

  defp orphaned(occurrences_by_id, paired_ids) do
    paired_ids = MapSet.new(paired_ids)

    occurrences_by_id
    |> Enum.reject(fn {tool_call_id, _occurrences} ->
      MapSet.member?(paired_ids, tool_call_id)
    end)
    |> Enum.map(fn {tool_call_id, occurrences} ->
      occurrences = Enum.sort_by(occurrences, & &1.index)

      %{
        indexes: occurrences_indexes(occurrences),
        message_ids: occurrence_message_ids(occurrences),
        tool_call_id: tool_call_id
      }
    end)
    |> Enum.sort_by(fn orphan -> List.first(orphan.indexes) end)
  end

  defp occurrences_indexes(occurrences), do: occurrences |> Enum.map(& &1.index) |> Enum.uniq()

  defp occurrence_message_ids(occurrences),
    do: occurrences |> Enum.map(& &1.message_id) |> Enum.uniq()

  defp unique_strings(values) do
    values
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end
end
