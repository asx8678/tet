defmodule Tet.Runtime.Tools.EventCapture do
  @moduledoc """
  BD-0022: Read-tool event capture for durable Event Log entries.

  Wraps a read-only tool invocation with structured event emission:

  - Emits a `read_tool.started` event before execution with the tool name,
    validated args, and redaction class from the contract.
  - Executes the tool via `Tet.Runtime.Tools.run_tool/3`.
  - Emits a `read_tool.completed` event after execution with a result summary,
    correlation metadata, and — for large results — an artifact reference
    instead of inline content.

  ## Large-result artifact references

  When the result payload exceeds `@large_result_bytes` (default 100 KB), the
  completed event records an `artifact_ref` map with a content hash and byte
  count instead of embedding the full result inline. The artifact store is a
  future concern (Phase 2); for now the reference is opaque metadata that
  allows future artifact lookups.

  ## Integration

  Callers pass optional correlation context (`session_id`, `task_id`,
  `tool_call_id`) and the contract's redaction class. The module is testable
  without a running EventBus by subscribing before the call or by inspecting
  the returned events.
  """

  alias Tet.Runtime.Tools

  @large_result_bytes 102_400
  @known_redaction_classes [:workspace_content, :workspace_metadata, :workspace_snippets, :workspace_diff, :operator_input]

  @doc """
  Runs a read-only tool with event capture.

  Returns `{:ok, result, [event]}` on success, or `{:error, result, [event]}`
  on tool failure. `result` is the envelope from `Tools.run_tool/3`. `events`
  is a list of `Tet.Event` structs (started + completed).

  ## Options

    - `:session_id` — durable session id for correlation
    - `:task_id` — optional durable task id
    - `:tool_call_id` — optional provider/runtime tool-call id
    - `:redaction_class` — redaction class atom from the tool contract
      (default: `:workspace_content`)
  """
  @spec run(String.t(), map(), keyword()) :: {:ok, map(), [Tet.Event.t()]} | {:error, map(), [Tet.Event.t()]}
  def run(tool_name, args, opts \\ []) when is_binary(tool_name) and is_map(args) and is_list(opts) do
    session_id = Keyword.get(opts, :session_id)
    task_id = Keyword.get(opts, :task_id)
    redaction_class = resolve_redaction_class(Keyword.get(opts, :redaction_class))
    tool_call_id = Keyword.get(opts, :tool_call_id)

    common =
      %{
        tool_name: tool_name,
        args: summary_args(args),
        redaction_class: redaction_class
      }
      |> add_optional(:session_id, session_id)
      |> add_optional(:task_id, task_id)
      |> add_optional(:tool_call_id, tool_call_id)

    started_event =
      Tet.Event.read_tool_started(
        common,
        session_id: session_id,
        metadata: %{correlation: correlation_meta(session_id, task_id, tool_call_id)}
      )

    publish_event(started_event)

    result = Tools.run_tool(tool_name, args, Keyword.drop(opts, [:session_id, :task_id, :tool_call_id, :redaction_class]))

    completed_payload =
      if result.ok do
        build_success_payload(tool_name, result, common)
      else
        build_error_payload(result, common)
      end

    completed_event =
      Tet.Event.read_tool_completed(
        completed_payload,
        session_id: session_id,
        metadata: %{correlation: correlation_meta(session_id, task_id, tool_call_id)}
      )

    publish_event(completed_event)

    if result.ok do
      {:ok, result, [started_event, completed_event]}
    else
      {:error, result, [started_event, completed_event]}
    end
  end

  @doc """
  Builds a summary of tool arguments safe for event logs.

  Redacts sensitive-looking keys and truncates long string values.
  """
  @spec summary_args(map()) :: map()
  def summary_args(args) when is_map(args) do
    args
    |> Map.take(~w(path query regex case_sensitive recursive max_depth start_line line_count include_globs exclude_globs))
    |> Enum.map(fn {k, v} -> {k, truncate_value(v)} end)
    |> Map.new()
  end

  defp truncate_value(value) when is_binary(value) and byte_size(value) > 512 do
    binary_part(value, 0, 512) <> "..."
  end

  defp truncate_value(value) when is_list(value), do: Enum.map(value, &truncate_value/1)
  defp truncate_value(value), do: value

  defp build_success_payload(tool_name, result, common) do
    data = result.data
    summary = summarize_result(tool_name, data)
    artifact_ref = maybe_artifact_ref(tool_name, data)

    common
    |> Map.put(:ok, true)
    |> Map.put(:result_summary, summary)
    |> put_if(artifact_ref, :artifact_ref)
  end

  defp build_error_payload(result, common) do
    error = result.error || %{}

    common
    |> Map.put(:ok, false)
    |> Map.put(:result_summary, %{
      error_code: Map.get(error, :code, "unknown"),
      error_message: Map.get(error, :message, "")
    })
  end

  defp summarize_result("read", data) when is_map(data) do
    %{
      bytes_read: Map.get(data, :bytes_read, 0),
      line_count: Map.get(data, :line_count, 0),
      total_lines: Map.get(data, :total_lines, 0),
      truncated: Map.get(data, :truncated, false) || Map.get(data, :binary, false)
    }
  end

  defp summarize_result("list", data) when is_map(data) do
    summary = Map.get(data, :summary, %{})
    %{
      entry_count: Map.get(summary, :entry_count, 0),
      file_count: Map.get(summary, :file_count, 0),
      directory_count: Map.get(summary, :directory_count, 0),
      total_bytes: Map.get(summary, :total_bytes, 0),
      truncated: Map.get(summary, :truncated, false)
    }
  end

  defp summarize_result("search", data) when is_map(data) do
    summary = Map.get(data, :summary, %{})
    %{
      match_count: Map.get(summary, :match_count, 0),
      file_count: Map.get(summary, :file_count, 0),
      truncated: Map.get(summary, :truncated, false)
    }
  end

  defp summarize_result(_tool_name, _data), do: %{}

  defp maybe_artifact_ref("read", data) when is_map(data) do
    content = Map.get(data, :content, "")
    bytes = byte_size(content)

    if bytes > @large_result_bytes do
      %{
        content_sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
        content_bytes: bytes,
        inline_truncated: true
      }
    end
  end

  defp maybe_artifact_ref("list", data) when is_map(data) do
    encoded = :erlang.term_to_binary(data)
    bytes = byte_size(encoded)

    if bytes > @large_result_bytes do
      %{
        content_sha256: :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower),
        content_bytes: bytes,
        inline_truncated: true
      }
    end
  end

  defp maybe_artifact_ref("search", data) when is_map(data) do
    matches = Map.get(data, :matches, [])
    encoded = :erlang.term_to_binary(matches)
    bytes = byte_size(encoded)

    if bytes > @large_result_bytes do
      match_count = length(matches)
      %{
        match_count: match_count,
        content_bytes: bytes,
        inline_truncated: true
      }
    end
  end

  defp maybe_artifact_ref(_tool_name, _data), do: nil

  defp resolve_redaction_class(nil), do: :workspace_content
  defp resolve_redaction_class(class) when class in @known_redaction_classes, do: class
  defp resolve_redaction_class(_), do: :workspace_content

  defp correlation_meta(session_id, task_id, tool_call_id) do
    %{}
    |> put_if_value(:session_id, session_id)
    |> put_if_value(:task_id, task_id)
    |> put_if_value(:tool_call_id, tool_call_id)
  end

  defp add_optional(map, _key, nil), do: map
  defp add_optional(map, key, value), do: Map.put(map, key, value)

  defp put_if(map, nil, _key), do: map
  defp put_if(map, value, key), do: Map.put(map, key, value)

  defp put_if_value(map, _key, nil), do: map
  defp put_if_value(map, _key, ""), do: map
  defp put_if_value(map, key, value), do: Map.put(map, key, value)

  defp publish_event(%Tet.Event{} = event) do
    Tet.EventBus.publish(Tet.Runtime.Timeline.all_topic(), event)

    case event.session_id do
      nil -> :ok
      session_id -> Tet.EventBus.publish({:session, session_id}, event)
    end
  end
end
