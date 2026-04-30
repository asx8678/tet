defmodule Tet.Runtime.Provider.OpenAICompatible do
  @moduledoc """
  Minimal OpenAI-compatible streaming chat adapter.

  It calls `/chat/completions` with `stream: true` and emits assistant chunks
  from Server-Sent Event `data:` payloads. No SDK, no web stack, no drama.

  Successful streams must end with `data: [DONE]`. Missing the sentinel,
  receiving content after it, or leaving a non-empty trailing SSE buffer is
  treated as incomplete/malformed.
  """

  @behaviour Tet.Provider

  @impl true
  def stream_chat(messages, opts, emit) when is_list(messages) and is_function(emit, 1) do
    with {:ok, request} <- request(messages, opts),
         :ok <- ensure_http_started(),
         {:ok, request_id} <- start_stream(request, opts) do
      collect_stream(request_id, opts, emit, "", [], false)
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

  defp collect_stream(request_id, opts, emit, buffer, chunks, done?) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        collect_stream(request_id, opts, emit, buffer, chunks, done?)

      {:http, {^request_id, :stream, part}} ->
        case handle_part(part, buffer, chunks, done?, opts, emit) do
          {:ok, buffer, chunks, done?} ->
            collect_stream(request_id, opts, emit, buffer, chunks, done?)

          {:error, reason} ->
            cancel_request(request_id)
            {:error, reason}
        end

      {:http, {^request_id, :stream_end, _headers}} ->
        finish(chunks, opts, done?, buffer)

      {:http, {^request_id, :stream_end}} ->
        finish(chunks, opts, done?, buffer)

      {:http, {^request_id, {{_version, status, reason_phrase}, _headers, body}}} ->
        {:error,
         {:provider_http_status, status, to_string(reason_phrase), IO.iodata_to_binary(body)}}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, {:provider_http_error, reason}}
    after
      timeout ->
        cancel_request(request_id)
        {:error, :provider_timeout}
    end
  end

  defp handle_part(part, buffer, chunks, done?, opts, emit) do
    data = buffer <> IO.iodata_to_binary(part)
    {payloads, rest} = sse_payloads(data)

    payloads
    |> Enum.reduce_while({:ok, chunks, done?}, fn payload, {:ok, acc, seen_done?} ->
      case decode_payload(payload) do
        {:chunk, _content} when seen_done? ->
          {:halt, {:error, :provider_stream_incomplete}}

        {:chunk, content} ->
          emit_chunk(content, opts, emit)
          {:cont, {:ok, [content | acc], seen_done?}}

        :done ->
          {:cont, {:ok, acc, true}}

        :skip ->
          {:cont, {:ok, acc, seen_done?}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, new_chunks, new_done?} -> {:ok, rest, new_chunks, new_done?}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish(_chunks, _opts, _done?, buffer) when byte_size(buffer) > 0 do
    {:error, :provider_stream_incomplete}
  end

  defp finish(chunks, opts, true, _buffer) do
    {:ok,
     %{
       content: chunks |> Enum.reverse() |> Enum.join(),
       provider: :openai_compatible,
       model: Keyword.fetch!(opts, :model)
     }}
  end

  defp finish(_chunks, _opts, false, _buffer), do: {:error, :provider_stream_incomplete}

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
      |> Enum.flat_map(&data_lines/1)
      |> Enum.reject(&(&1 == ""))

    {payloads, rest}
  end

  defp ends_with_blank_line?(data) when byte_size(data) < 2, do: false

  defp ends_with_blank_line?(data) do
    binary_part(data, byte_size(data) - 2, 2) == "\n\n"
  end

  defp data_lines(block) do
    block
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(fn "data:" <> value -> String.trim_leading(value) end)
  end

  defp decode_payload("[DONE]"), do: :done

  defp decode_payload(payload) do
    payload
    |> :json.decode()
    |> content_from_chunk()
  rescue
    exception -> {:error, {:invalid_provider_chunk, Exception.message(exception)}}
  end

  defp content_from_chunk(%{"choices" => choices}) when is_list(choices) do
    choices
    |> List.first()
    |> case do
      %{"delta" => %{"content" => content}} when is_binary(content) -> {:chunk, content}
      %{"message" => %{"content" => content}} when is_binary(content) -> {:chunk, content}
      _ -> :skip
    end
  end

  defp content_from_chunk(_), do: :skip

  defp emit_chunk(content, opts, emit) do
    emit.(%Tet.Event{
      type: :assistant_chunk,
      session_id: Keyword.get(opts, :session_id),
      payload: %{
        content: content,
        provider: :openai_compatible,
        model: Keyword.get(opts, :model)
      }
    })
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
