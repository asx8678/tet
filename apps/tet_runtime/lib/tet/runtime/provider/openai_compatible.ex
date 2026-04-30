defmodule Tet.Runtime.Provider.OpenAICompatible do
  @moduledoc """
  Minimal OpenAI-compatible streaming chat adapter.

  It calls `/chat/completions` with `stream: true` and emits normalized provider
  lifecycle events from Server-Sent Event `data:` payloads. A legacy
  `:assistant_chunk` event is also emitted after each text delta so existing CLI
  streaming keeps working while newer consumers move to `:provider_text_delta`.

  Successful streams must end with `data: [DONE]`. Missing the sentinel,
  receiving content after it, or leaving a non-empty trailing SSE buffer is
  treated as incomplete/malformed.
  """

  @behaviour Tet.Provider

  alias Tet.Runtime.Provider.StreamEvents

  @provider :openai_compatible

  @impl true
  def cache_capability, do: :summary

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

  defp do_stream_chat(messages, opts, emit) do
    with {:ok, request} <- request(messages, opts),
         :ok <- ensure_http_started(),
         {:ok, request_id} <- start_stream(request, opts) do
      StreamEvents.emit_start(@provider, opts, emit)

      collect_stream(request_id, opts, emit, %{
        buffer: "",
        chunks: [],
        done?: false,
        emitted_done?: false,
        stop_reason: nil,
        tool_calls: %{}
      })
    else
      {:error, reason} -> return_error(reason, opts, emit)
    end
  end

  defp request(messages, opts) do
    with {:ok, base_url} <- required_binary(opts, :base_url),
         {:ok, api_key} <- required_binary(opts, :api_key),
         {:ok, model} <- required_binary(opts, :model) do
      url = base_url |> String.trim_trailing("/") |> Kernel.<>("/chat/completions")

      body =
        %{
          model: model,
          stream: true,
          stream_options: %{include_usage: true},
          messages: Enum.map(messages, &message_to_provider/1)
        }
        |> :json.encode()
        |> IO.iodata_to_binary()

      headers = [
        {~c"authorization", String.to_charlist("Bearer " <> api_key)},
        {~c"accept", ~c"text/event-stream"}
      ]

      {:ok, {String.to_charlist(url), headers, ~c"application/json", body}}
    end
  end

  defp start_stream(request, opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    http_options = [timeout: timeout, connect_timeout: timeout]
    options = [sync: false, stream: :self, body_format: :binary]

    :httpc.request(:post, request, http_options, options)
  end

  defp collect_stream(request_id, opts, emit, state) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        collect_stream(request_id, opts, emit, state)

      {:http, {^request_id, :stream, part}} ->
        case handle_part(part, state, opts, emit) do
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

  defp handle_part(part, state, opts, emit) do
    data = state.buffer <> IO.iodata_to_binary(part)
    {payloads, rest} = sse_payloads(data)
    state = %{state | buffer: rest}

    Enum.reduce_while(payloads, {:ok, state}, fn payload, {:ok, acc} ->
      case handle_payload(payload, acc, opts, emit) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp handle_payload("[DONE]", state, _opts, _emit) do
    {:ok, %{state | done?: true}}
  end

  defp handle_payload(_payload, %{done?: true}, _opts, _emit),
    do: {:error, :provider_stream_incomplete}

  defp handle_payload(payload, state, opts, emit) do
    case decode_payload(payload) do
      {:ok, chunk} -> apply_chunk(chunk, state, opts, emit)
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_chunk(chunk, state, opts, emit) do
    with {:ok, state} <- apply_usage(chunk.usage, state, opts, emit),
         {:ok, state} <- apply_text(chunk.text, state, opts, emit),
         {:ok, state} <- apply_tool_call_deltas(chunk.tool_call_deltas, state, opts, emit),
         {:ok, state} <- apply_finish_reason(chunk.finish_reason, state, opts, emit) do
      {:ok, state}
    end
  end

  defp apply_usage(nil, state, _opts, _emit), do: {:ok, state}

  defp apply_usage(usage, state, opts, emit) do
    StreamEvents.emit_usage(@provider, usage, opts, emit)
    {:ok, state}
  end

  defp apply_text(nil, state, _opts, _emit), do: {:ok, state}
  defp apply_text("", state, _opts, _emit), do: {:ok, state}

  defp apply_text(text, state, opts, emit) do
    StreamEvents.emit_text_delta(@provider, text, opts, emit)
    {:ok, %{state | chunks: [text | state.chunks]}}
  end

  defp apply_tool_call_deltas([], state, _opts, _emit), do: {:ok, state}

  defp apply_tool_call_deltas(deltas, state, opts, emit) do
    state =
      Enum.reduce(deltas, state, fn delta, acc ->
        StreamEvents.emit_tool_call_delta(@provider, delta, opts, emit)
        put_tool_call_delta(acc, delta)
      end)

    {:ok, state}
  end

  defp apply_finish_reason(nil, state, _opts, _emit), do: {:ok, state}

  defp apply_finish_reason("tool_calls", state, opts, emit) do
    with {:ok, state} <- emit_tool_call_done_events(state, opts, emit) do
      {:ok, record_stop_reason(state, :tool_use)}
    end
  end

  defp apply_finish_reason(reason, state, _opts, _emit) when is_binary(reason) do
    {:ok, record_stop_reason(state, stop_reason(reason))}
  end

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

  defp finish(_state, opts, emit), do: return_error(:provider_stream_incomplete, opts, emit)

  defp sse_payloads(data) do
    normalized = :binary.replace(data, "\r\n", "\n", [:global])
    parts = :binary.split(normalized, "\n\n", [:global])

    {complete, rest} =
      if ends_with_blank_line?(normalized) do
        {parts, ""}
      else
        {Enum.drop(parts, -1), List.last(parts) || ""}
      end

    payloads =
      complete
      |> Enum.map(&data_payload/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    {payloads, rest}
  end

  defp ends_with_blank_line?(data) when byte_size(data) < 2, do: false

  defp ends_with_blank_line?(data) do
    binary_part(data, byte_size(data) - 2, 2) == "\n\n"
  end

  defp data_payload(block) do
    lines =
      block
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn "data:" <> value -> String.trim_leading(value) end)

    case lines do
      [] -> nil
      _lines -> Enum.join(lines, "\n")
    end
  end

  defp decode_payload(payload) do
    payload
    |> :json.decode()
    |> chunk_from_decoded()
  rescue
    exception ->
      {:error, {:invalid_provider_chunk, preview(payload), Exception.message(exception)}}
  end

  defp chunk_from_decoded(decoded) when is_map(decoded) do
    with {:ok, usage} <- usage_from_decoded(Map.get(decoded, "usage")),
         {:ok, choice} <- first_choice(Map.get(decoded, "choices")),
         {:ok, parsed_choice} <- parse_choice(choice) do
      {:ok, Map.put(parsed_choice, :usage, usage)}
    end
  end

  defp chunk_from_decoded(_decoded), do: {:error, {:invalid_provider_chunk, :not_a_map}}

  defp first_choice(nil), do: {:error, {:invalid_provider_chunk, :missing_choices}}
  defp first_choice([]), do: {:ok, nil}
  defp first_choice([choice | _rest]), do: {:ok, choice}
  defp first_choice(_choices), do: {:error, {:invalid_provider_chunk, :invalid_choices}}

  defp parse_choice(nil), do: {:ok, empty_chunk()}

  defp parse_choice(choice) when is_map(choice) do
    with {:ok, delta} <- optional_map(Map.get(choice, "delta"), :delta),
         {:ok, message} <- optional_map(Map.get(choice, "message"), :message),
         {:ok, text} <- text_from_choice(delta, message),
         {:ok, tool_call_deltas} <- tool_call_deltas_from_delta(Map.get(delta, "tool_calls")),
         {:ok, finish_reason} <- finish_reason_from_choice(Map.get(choice, "finish_reason")) do
      {:ok,
       %{
         empty_chunk()
         | text: text,
           tool_call_deltas: tool_call_deltas,
           finish_reason: finish_reason
       }}
    end
  end

  defp parse_choice(_choice), do: {:error, {:invalid_provider_chunk, :invalid_choice}}

  defp empty_chunk do
    %{text: nil, tool_call_deltas: [], finish_reason: nil, usage: nil}
  end

  defp text_from_choice(delta, message) do
    case {Map.get(delta, "content"), Map.get(message, "content")} do
      {content, _message_content} when is_binary(content) ->
        {:ok, content}

      {nil, content} when is_binary(content) ->
        {:ok, content}

      {nil, nil} ->
        {:ok, nil}

      {content, _message_content} ->
        {:error, {:invalid_provider_chunk, {:invalid_content, content}}}
    end
  end

  defp tool_call_deltas_from_delta(nil), do: {:ok, []}

  defp tool_call_deltas_from_delta(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {tool_call, position}, {:ok, acc} ->
      case tool_call_delta_from_provider(tool_call, position) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, delta} -> {:cont, {:ok, [delta | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, deltas} -> {:ok, Enum.reverse(deltas)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tool_call_deltas_from_delta(_tool_calls),
    do: {:error, {:invalid_provider_chunk, :invalid_tool_calls}}

  defp tool_call_delta_from_provider(tool_call, fallback_index) when is_map(tool_call) do
    with {:ok, function} <- optional_map(Map.get(tool_call, "function"), :function),
         {:ok, index} <- non_negative_index(Map.get(tool_call, "index"), fallback_index),
         {:ok, id} <- optional_binary(Map.get(tool_call, "id"), :id),
         {:ok, name} <- optional_binary(Map.get(function, "name"), :name),
         {:ok, arguments_delta} <- optional_binary(Map.get(function, "arguments"), :arguments) do
      delta = %{
        index: index,
        id: id,
        name: name,
        arguments_delta: arguments_delta || ""
      }

      if id || name || delta.arguments_delta != "" do
        {:ok, delta}
      else
        {:ok, nil}
      end
    end
  end

  defp tool_call_delta_from_provider(_tool_call, _fallback_index),
    do: {:error, {:invalid_provider_chunk, :invalid_tool_call}}

  defp usage_from_decoded(nil), do: {:ok, nil}

  defp usage_from_decoded(usage) when is_map(usage) do
    normalized =
      %{}
      |> maybe_put(:input_tokens, token_count(usage, ["prompt_tokens", "input_tokens"]))
      |> maybe_put(:output_tokens, token_count(usage, ["completion_tokens", "output_tokens"]))
      |> maybe_put(:total_tokens, token_count(usage, ["total_tokens"]))

    normalized = maybe_put(normalized, :raw, usage)

    if map_size(normalized) == 1 and Map.has_key?(normalized, :raw) do
      {:ok, nil}
    else
      {:ok, normalized}
    end
  end

  defp usage_from_decoded(_usage), do: {:error, {:invalid_provider_chunk, :invalid_usage}}

  defp token_count(usage, keys) do
    keys
    |> Enum.map(&Map.get(usage, &1))
    |> Enum.find(&(is_integer(&1) and &1 >= 0))
  end

  defp finish_reason_from_choice(nil), do: {:ok, nil}
  defp finish_reason_from_choice(reason) when is_binary(reason), do: {:ok, reason}

  defp finish_reason_from_choice(reason),
    do: {:error, {:invalid_provider_chunk, {:invalid_finish_reason, reason}}}

  defp put_tool_call_delta(%{tool_calls: tool_calls} = state, delta) do
    current = Map.get(tool_calls, delta.index, %{id: nil, name: nil, arguments_json: ""})

    updated = %{
      current
      | id: delta.id || current.id,
        name: delta.name || current.name,
        arguments_json: current.arguments_json <> delta.arguments_delta
    }

    %{state | tool_calls: Map.put(tool_calls, delta.index, updated)}
  end

  defp emit_tool_call_done_events(%{tool_calls: tool_calls} = state, opts, emit) do
    tool_calls
    |> Enum.sort_by(fn {index, _tool_call} -> index end)
    |> Enum.reduce_while({:ok, state}, fn {index, tool_call}, {:ok, acc} ->
      case complete_tool_call(index, tool_call) do
        {:ok, done} ->
          StreamEvents.emit_tool_call_done(@provider, done, opts, emit)
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp complete_tool_call(index, %{id: id, name: name, arguments_json: arguments_json}) do
    with {:ok, name} <- required_tool_name(name, index),
         {:ok, arguments} <- decode_tool_arguments(arguments_json, index) do
      {:ok, %{index: index, id: id || "call_#{index}", name: name, arguments: arguments}}
    end
  end

  defp required_tool_name(name, _index) when is_binary(name) and name != "", do: {:ok, name}

  defp required_tool_name(_name, index),
    do: {:error, {:invalid_provider_chunk, {:missing_tool_name, index}}}

  defp decode_tool_arguments(arguments_json, _index) when arguments_json in [nil, ""],
    do: {:ok, %{}}

  defp decode_tool_arguments(arguments_json, index) do
    case :json.decode(arguments_json) do
      arguments when is_map(arguments) -> {:ok, arguments}
      _arguments -> {:error, {:invalid_tool_arguments, index, :not_a_map}}
    end
  rescue
    exception -> {:error, {:invalid_tool_arguments, index, Exception.message(exception)}}
  end

  defp maybe_emit_done(%{emitted_done?: true} = state, _stop_reason, _opts, _emit), do: state

  defp maybe_emit_done(state, stop_reason, opts, emit) do
    stop_reason = state.stop_reason || stop_reason

    StreamEvents.emit_done(@provider, stop_reason, opts, emit)
    %{state | emitted_done?: true, stop_reason: stop_reason}
  end

  defp record_stop_reason(%{stop_reason: nil} = state, stop_reason),
    do: %{state | stop_reason: stop_reason}

  defp record_stop_reason(state, _stop_reason), do: state

  defp stop_reason("stop"), do: :stop
  defp stop_reason("length"), do: :length
  defp stop_reason("tool_calls"), do: :tool_use
  defp stop_reason(_reason), do: :error

  defp optional_map(nil, _field), do: {:ok, %{}}
  defp optional_map(value, _field) when is_map(value), do: {:ok, value}

  defp optional_map(value, field),
    do: {:error, {:invalid_provider_chunk, {:invalid_field, field, value}}}

  defp non_negative_index(nil, fallback_index), do: {:ok, fallback_index}

  defp non_negative_index(index, _fallback_index) when is_integer(index) and index >= 0,
    do: {:ok, index}

  defp non_negative_index(index, _fallback_index),
    do: {:error, {:invalid_provider_chunk, {:invalid_tool_index, index}}}

  defp optional_binary(nil, _field), do: {:ok, nil}
  defp optional_binary(value, _field) when is_binary(value), do: {:ok, value}

  defp optional_binary(value, field),
    do: {:error, {:invalid_provider_chunk, {:invalid_tool_field, field, value}}}

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp preview(payload) when is_binary(payload) do
    String.slice(payload, 0, 200)
  end

  defp return_error(reason, opts, emit) do
    StreamEvents.emit_error(@provider, reason, opts, emit)
    {:error, reason}
  end

  defp message_to_provider(%Tet.Message{} = message) do
    %{role: Atom.to_string(message.role), content: message.content}
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
end
