defmodule Tet.Runtime.Provider.Anthropic do
  @moduledoc """
  Native Anthropic Messages API streaming adapter.

  Streams against `POST /v1/messages` with `stream: true`, parsing Anthropic's
  SSE event types (`message_start`, `content_block_start`, `content_block_delta`,
  `content_block_stop`, `message_delta`, `message_stop`) into normalized provider
  lifecycle events.

  System messages are extracted from the message list and sent as the top-level
  `system` field per the Anthropic API contract. Tool results are converted from
  `role: :tool` messages to `user` messages with `tool_result` content blocks.

  Anthropic's SSE does not use the `data: [DONE]` sentinel — stream termination
  is signalled by `message_stop`. Missing `message_stop` at EOF is treated as
  `:invalid_response` (§11 / S3 — terminal event is mandatory).
  """

  @behaviour Tet.Provider

  alias Tet.Runtime.Provider.StreamEvents

  @provider :anthropic

  @default_api_url "https://api.anthropic.com"
  @anthropic_version "2023-06-01"

  # --- Behaviour callbacks ---

  @impl true
  def cache_capability, do: :full

  @impl true
  def stream_chat(messages, opts, emit) when is_list(messages) and is_function(emit, 1) do
    do_stream_chat(messages, opts, emit)
  rescue
    exception ->
      reason = {:provider_adapter_exception, Exception.message(exception)}
      StreamEvents.emit_error(@provider, reason, opts, emit)
      {:error, reason}
  catch
    kind, value ->
      reason = {:provider_adapter_exit, kind, value}
      StreamEvents.emit_error(@provider, reason, opts, emit)
      {:error, reason}
  end

  # --- Request construction ---

  defp do_stream_chat(messages, opts, emit) do
    with {:ok, request} <- request(messages, opts),
         :ok <- ensure_http_started(),
         {:ok, request_id} <- start_stream(request, opts) do
      collect_stream(request_id, opts, emit, initial_state())
    else
      {:error, reason} -> return_error(reason, opts, emit)
    end
  end

  defp request(messages, opts) do
    with {:ok, api_key} <- required_binary(opts, :api_key),
         {:ok, model} <- required_binary(opts, :model) do
      base_url = Keyword.get(opts, :base_url, @default_api_url)
      url = base_url |> String.trim_trailing("/") |> Kernel.<>("/v1/messages")

      {system, chat_messages} = extract_system(messages)

      body =
        %{
          model: model,
          stream: true,
          max_tokens: Keyword.get(opts, :max_tokens, 8192),
          messages: Enum.map(chat_messages, &message_to_provider/1)
        }
        |> maybe_put_system(system)
        |> maybe_put_tools(opts)
        |> :json.encode()
        |> IO.iodata_to_binary()

      headers = [
        {~c"x-api-key", String.to_charlist(api_key)},
        {~c"anthropic-version", ~c"#{@anthropic_version}"},
        {~c"accept", ~c"text/event-stream"}
      ]

      {:ok, {String.to_charlist(url), headers, ~c"application/json", body}}
    end
  end

  defp extract_system(messages) do
    {system_msgs, rest} =
      Enum.split_with(messages, fn
        %Tet.Message{role: :system} -> true
        _ -> false
      end)

    system =
      case system_msgs do
        [] -> nil
        msgs -> msgs |> Enum.map(& &1.content) |> Enum.join("\n\n")
      end

    {system, rest}
  end

  defp message_to_provider(%Tet.Message{role: :tool} = message) do
    tool_call_id =
      Map.get(message.metadata, :tool_call_id) || Map.get(message.metadata, "tool_call_id")

    %{
      role: "user",
      content: [
        %{
          type: "tool_result",
          tool_use_id: tool_call_id,
          content: message.content
        }
      ]
    }
  end

  defp message_to_provider(%Tet.Message{role: :assistant, metadata: %{tool_calls: tool_calls}})
       when is_list(tool_calls) and tool_calls != [] do
    content =
      Enum.map(tool_calls, fn tc ->
        %{
          type: "tool_use",
          id: tc.id || tc["id"],
          name: tc.name || tc["name"],
          input: tc.arguments || tc["arguments"] || %{}
        }
      end)

    %{role: "assistant", content: content}
  end

  defp message_to_provider(%Tet.Message{} = message) do
    %{role: Atom.to_string(message.role), content: message.content}
  end

  defp maybe_put_system(body, nil), do: body
  defp maybe_put_system(body, system), do: Map.put(body, :system, system)

  defp maybe_put_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      tools when is_list(tools) and tools != [] ->
        Map.put(body, :tools, Enum.map(tools, &tool_to_provider/1))

      _ ->
        body
    end
  end

  defp tool_to_provider(tool) when is_map(tool) do
    %{
      name: tool[:name] || tool["name"],
      description: tool[:description] || tool["description"] || "",
      input_schema:
        tool[:parameters] || tool[:input_schema] || tool["parameters"] || tool["input_schema"] ||
          %{}
    }
  end

  # --- HTTP streaming ---

  defp start_stream(request, opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    http_options = [timeout: timeout, connect_timeout: timeout]
    options = [sync: false, stream: :self, body_format: :binary]

    :httpc.request(:post, request, http_options, options)
  end

  defp initial_state do
    %{
      buffer: "",
      chunks: [],
      started?: false,
      done?: false,
      emitted_done?: false,
      stop_reason: nil,
      content_blocks: %{},
      tool_calls: %{},
      usage: nil
    }
  end

  defp collect_stream(request_id, opts, emit, state) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        collect_stream(request_id, opts, emit, state)

      {:http, {^request_id, :stream, part}} ->
        case handle_part(part, state, opts, emit) do
          {:ok, %{done?: true} = state} ->
            finish(state, opts, emit)

          {:ok, state} ->
            collect_stream(request_id, opts, emit, state)

          {:error, reason} ->
            cancel_request(request_id)
            return_error(reason, opts, emit)
        end

      {:http, {^request_id, :stream_end, _headers}} ->
        finish(state, opts, emit)

      {:http, {^request_id, :stream_end}} ->
        finish(state, opts, emit)

      {:http, {^request_id, {{_version, status, reason_phrase}, _headers, body}}} ->
        return_error(
          {:provider_http_status, status, to_string(reason_phrase), IO.iodata_to_binary(body)},
          opts,
          emit
        )

      {:http, {^request_id, {:error, reason}}} ->
        return_error({:provider_http_error, reason}, opts, emit)
    after
      timeout ->
        cancel_request(request_id)
        return_error(:provider_timeout, opts, emit)
    end
  end

  # --- SSE parsing ---

  defp handle_part(part, state, opts, emit) do
    data = state.buffer <> IO.iodata_to_binary(part)
    {events, rest} = parse_sse_events(data)
    state = %{state | buffer: rest}

    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, acc} ->
      case handle_sse_event(event, acc, opts, emit) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  def parse_sse_events(data) do
    normalized = :binary.replace(data, "\r\n", "\n", [:global])
    parts = :binary.split(normalized, "\n\n", [:global])

    {complete, rest} =
      if ends_with_blank_line?(normalized) do
        {parts, ""}
      else
        {Enum.drop(parts, -1), List.last(parts) || ""}
      end

    events =
      complete
      |> Enum.map(&parse_sse_block/1)
      |> Enum.reject(&is_nil/1)

    {events, rest}
  end

  defp ends_with_blank_line?(data) when byte_size(data) < 2, do: false

  defp ends_with_blank_line?(data) do
    binary_part(data, byte_size(data) - 2, 2) == "\n\n"
  end

  defp parse_sse_block(block) do
    lines = String.split(block, "\n")

    event_type =
      lines
      |> Enum.find_value(fn
        "event:" <> value -> String.trim(value)
        "event: " <> value -> String.trim(value)
        _ -> nil
      end)

    data_lines =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn "data:" <> value -> String.trim_leading(value) end)

    case data_lines do
      [] -> nil
      _ -> %{event: event_type, data: Enum.join(data_lines, "\n")}
    end
  end

  # --- Event handling ---

  defp handle_sse_event(%{data: data}, state, opts, emit) do
    case decode_data(data) do
      {:ok, decoded} -> apply_event(decoded, state, opts, emit)
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_data(data) do
    decoded = :json.decode(data)
    {:ok, decoded}
  rescue
    exception ->
      {:error, {:invalid_provider_chunk, preview(data), Exception.message(exception)}}
  end

  defp apply_event(%{"type" => "message_start"} = event, state, opts, emit) do
    StreamEvents.emit_start(@provider, opts, emit)

    usage = get_in(event, ["message", "usage"])
    state = %{state | started?: true}
    state = maybe_track_input_usage(state, usage)

    {:ok, state}
  end

  defp apply_event(%{"type" => "content_block_start"} = event, state, _opts, _emit) do
    index = event["index"]
    block = event["content_block"] || %{}
    block_type = block["type"]

    state =
      case block_type do
        "tool_use" ->
          tool = %{
            id: block["id"],
            name: block["name"],
            arguments_json: ""
          }

          %{
            state
            | content_blocks: Map.put(state.content_blocks, index, :tool_use),
              tool_calls: Map.put(state.tool_calls, index, tool)
          }

        _ ->
          %{state | content_blocks: Map.put(state.content_blocks, index, block_type)}
      end

    {:ok, state}
  end

  defp apply_event(%{"type" => "content_block_delta"} = event, state, opts, emit) do
    index = event["index"]
    delta = event["delta"] || %{}
    delta_type = delta["type"]

    case delta_type do
      "text_delta" ->
        text = delta["text"] || ""

        if text != "" do
          StreamEvents.emit_text_delta(@provider, text, opts, emit)
        end

        {:ok, %{state | chunks: [text | state.chunks]}}

      "input_json_delta" ->
        partial = delta["partial_json"] || ""
        tool = Map.get(state.tool_calls, index, %{id: nil, name: nil, arguments_json: ""})

        StreamEvents.emit_tool_call_delta(
          @provider,
          %{
            index: index,
            id: tool[:id],
            name: tool[:name],
            arguments_delta: partial
          },
          opts,
          emit
        )

        updated_tool = %{tool | arguments_json: tool.arguments_json <> partial}
        {:ok, %{state | tool_calls: Map.put(state.tool_calls, index, updated_tool)}}

      _ ->
        {:ok, state}
    end
  end

  defp apply_event(%{"type" => "content_block_stop"} = event, state, opts, emit) do
    index = event["index"]

    case Map.get(state.content_blocks, index) do
      :tool_use ->
        case complete_tool_call(index, Map.get(state.tool_calls, index)) do
          {:ok, done} ->
            StreamEvents.emit_tool_call_done(@provider, done, opts, emit)
            {:ok, state}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, state}
    end
  end

  defp apply_event(%{"type" => "message_delta"} = event, state, opts, emit) do
    delta = event["delta"] || %{}
    usage = event["usage"]

    stop_reason = delta["stop_reason"]

    state =
      if stop_reason, do: record_stop_reason(state, map_stop_reason(stop_reason)), else: state

    state =
      if usage do
        output_tokens = usage["output_tokens"]
        input_tokens = (state.usage || %{})[:input_tokens]

        merged =
          %{}
          |> maybe_put(:input_tokens, input_tokens)
          |> maybe_put(:output_tokens, output_tokens)

        if map_size(merged) > 0 do
          StreamEvents.emit_usage(@provider, merged, opts, emit)
        end

        %{state | usage: merged}
      else
        state
      end

    {:ok, state}
  end

  defp apply_event(%{"type" => "message_stop"}, state, _opts, _emit) do
    {:ok, %{state | done?: true}}
  end

  defp apply_event(%{"type" => "ping"}, state, _opts, _emit) do
    {:ok, state}
  end

  defp apply_event(%{"type" => "error"} = event, _state, _opts, _emit) do
    error = event["error"] || %{}
    detail = error["message"] || "unknown provider error"
    {:error, {:provider_http_error, detail}}
  end

  defp apply_event(_event, state, _opts, _emit) do
    # Unknown event types are silently ignored per SSE spec
    {:ok, state}
  end

  # --- Tool call completion ---

  defp complete_tool_call(index, %{id: id, name: name, arguments_json: arguments_json}) do
    with {:ok, name} <- required_tool_name(name, index),
         {:ok, arguments} <- decode_tool_arguments(arguments_json, index) do
      {:ok, %{index: index, id: id || "toolu_#{index}", name: name, arguments: arguments}}
    end
  end

  defp complete_tool_call(index, _tool) do
    {:error, {:invalid_provider_chunk, {:missing_tool_data, index}}}
  end

  defp required_tool_name(name, _index) when is_binary(name) and name != "", do: {:ok, name}

  defp required_tool_name(_name, index),
    do: {:error, {:invalid_provider_chunk, {:missing_tool_name, index}}}

  defp decode_tool_arguments(json, _index) when json in [nil, ""], do: {:ok, %{}}

  defp decode_tool_arguments(json, index) do
    case :json.decode(json) do
      arguments when is_map(arguments) -> {:ok, arguments}
      _other -> {:error, {:invalid_tool_arguments, index, :not_a_map}}
    end
  rescue
    exception -> {:error, {:invalid_tool_arguments, index, Exception.message(exception)}}
  end

  # --- Stop reason mapping (§11) ---

  defp map_stop_reason("end_turn"), do: :stop
  defp map_stop_reason("max_tokens"), do: :length
  defp map_stop_reason("tool_use"), do: :tool_use
  defp map_stop_reason(_reason), do: :error

  # --- Stream finalization ---

  defp finish(%{buffer: buffer}, opts, emit) when byte_size(buffer) > 0 do
    return_error(:provider_stream_incomplete, opts, emit)
  end

  defp finish(%{done?: true} = state, opts, emit) do
    state = maybe_emit_done(state, :stop, opts, emit)

    {:ok,
     %{
       content: state.chunks |> Enum.reverse() |> Enum.join(),
       provider: @provider,
       model: Keyword.fetch!(opts, :model),
       metadata: %{stop_reason: state.stop_reason || :stop}
     }}
  end

  defp finish(%{started?: false}, opts, emit) do
    return_error(:provider_stream_incomplete, opts, emit)
  end

  defp finish(_state, opts, emit) do
    return_error(:provider_stream_incomplete, opts, emit)
  end

  # --- Usage tracking ---

  defp maybe_track_input_usage(state, nil), do: state

  defp maybe_track_input_usage(state, usage) when is_map(usage) do
    input_tokens = usage["input_tokens"]

    if input_tokens do
      %{state | usage: %{input_tokens: input_tokens}}
    else
      state
    end
  end

  # --- State helpers ---

  defp maybe_emit_done(%{emitted_done?: true} = state, _stop_reason, _opts, _emit), do: state

  defp maybe_emit_done(state, stop_reason, opts, emit) do
    stop_reason = state.stop_reason || stop_reason
    StreamEvents.emit_done(@provider, stop_reason, opts, emit)
    %{state | emitted_done?: true, stop_reason: stop_reason}
  end

  defp record_stop_reason(%{stop_reason: nil} = state, stop_reason),
    do: %{state | stop_reason: stop_reason}

  defp record_stop_reason(state, _stop_reason), do: state

  # --- Shared helpers ---

  defp return_error(reason, opts, emit) do
    StreamEvents.emit_error(@provider, reason, opts, emit)
    {:error, reason}
  end

  defp required_binary(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_provider_option, key}}
    end
  end

  defp ensure_http_started do
    with {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, _} <- Application.ensure_all_started(:inets) do
      :ok
    else
      {:error, reason} -> {:error, {:provider_http_unavailable, reason}}
    end
  end

  defp cancel_request(request_id) do
    :httpc.cancel_request(request_id)
  catch
    _, _ -> :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp preview(data) when is_binary(data), do: String.slice(data, 0, 200)
end
