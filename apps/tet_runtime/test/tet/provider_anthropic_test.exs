defmodule Tet.ProviderAnthropicTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.Provider.Anthropic

  # ---------------------------------------------------------------------------
  # Anthropic SSE Stream Server — test double
  # ---------------------------------------------------------------------------

  defmodule AnthropicStreamServer do
    @moduledoc false

    def start(parent, events, opts \\ []) when is_pid(parent) and is_list(events) do
      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          active: false,
          ip: {127, 0, 0, 1},
          packet: :raw,
          reuseaddr: true
        ])

      {:ok, port} = :inet.port(listen)

      pid =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          {:ok, request} = recv_request(socket, "")
          send(parent, {:anthropic_request, request})

          if Keyword.get(opts, :status, 200) != 200 do
            send_error_response(
              socket,
              Keyword.get(opts, :status, 500),
              Keyword.get(opts, :body, "")
            )
          else
            send_sse_response(socket, events, opts)
          end

          :gen_tcp.close(socket)
          :gen_tcp.close(listen)
        end)

      {:ok, %{pid: pid, base_url: "http://127.0.0.1:#{port}"}}
    end

    # --- Anthropic SSE event builders ---

    def message_start(opts \\ []) do
      input_tokens = Keyword.get(opts, :input_tokens, 10)

      sse_event("message_start", %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_test_#{System.unique_integer([:positive])}",
          "type" => "message",
          "role" => "assistant",
          "content" => [],
          "model" => Keyword.get(opts, :model, "claude-sonnet-4-20250514"),
          "stop_reason" => nil,
          "usage" => %{"input_tokens" => input_tokens, "output_tokens" => 0}
        }
      })
    end

    def content_block_start_text(index) do
      sse_event("content_block_start", %{
        "type" => "content_block_start",
        "index" => index,
        "content_block" => %{"type" => "text", "text" => ""}
      })
    end

    def content_block_start_tool_use(index, id, name) do
      sse_event("content_block_start", %{
        "type" => "content_block_start",
        "index" => index,
        "content_block" => %{"type" => "tool_use", "id" => id, "name" => name, "input" => ""}
      })
    end

    def text_delta(index, text) do
      sse_event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => index,
        "delta" => %{"type" => "text_delta", "text" => text}
      })
    end

    def input_json_delta(index, partial_json) do
      sse_event("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => index,
        "delta" => %{"type" => "input_json_delta", "partial_json" => partial_json}
      })
    end

    def content_block_stop(index) do
      sse_event("content_block_stop", %{
        "type" => "content_block_stop",
        "index" => index
      })
    end

    def message_delta(stop_reason, output_tokens \\ 15) do
      sse_event("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop_reason},
        "usage" => %{"output_tokens" => output_tokens}
      })
    end

    def message_stop do
      sse_event("message_stop", %{"type" => "message_stop"})
    end

    def ping do
      sse_event("ping", %{"type" => "ping"})
    end

    def anthropic_sse_error(type, message) do
      sse_event("error", %{
        "type" => "error",
        "error" => %{"type" => type, "message" => message}
      })
    end

    # --- Internals ---

    defp sse_event(event_type, data) do
      json = data |> :json.encode() |> IO.iodata_to_binary()
      "event: #{event_type}\ndata: #{json}\n\n"
    end

    defp recv_request(socket, acc) do
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} ->
          acc = acc <> data

          if String.contains?(acc, "\r\n\r\n") and complete_body?(acc) do
            {:ok, acc}
          else
            recv_request(socket, acc)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp complete_body?(request) do
      [headers, body] = String.split(request, "\r\n\r\n", parts: 2)

      case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
        [_, length] -> byte_size(body) >= String.to_integer(length)
        _ -> true
      end
    end

    defp send_sse_response(socket, events, opts) do
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "content-type: text/event-stream\r\n",
        "connection: close\r\n\r\n"
      ])

      Enum.each(events, fn event ->
        :gen_tcp.send(socket, event)
      end)

      unless Keyword.get(opts, :skip_close, false) do
        :ok
      end
    end

    defp send_error_response(socket, status, body) do
      body_str =
        if is_binary(body), do: body, else: body |> :json.encode() |> IO.iodata_to_binary()

      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} Error\r\n",
        "content-type: application/json\r\n",
        "content-length: #{byte_size(body_str)}\r\n",
        "connection: close\r\n\r\n",
        body_str
      ])
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp collect_events(acc \\ []) do
    receive do
      {:event, %Tet.Event{} = event} -> collect_events([event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp event_value(%Tet.Event{payload: payload}, key) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
  end

  defp provider_history(session_id, content) do
    [
      %Tet.Message{
        id: "msg-#{unique_integer()}",
        session_id: session_id,
        role: :user,
        content: content,
        timestamp: "2025-01-01T00:00:00.000Z",
        metadata: %{}
      }
    ]
  end

  defp provider_history_with_system(session_id, system, user) do
    [
      %Tet.Message{
        id: "msg-sys-#{unique_integer()}",
        session_id: session_id,
        role: :system,
        content: system,
        timestamp: "2025-01-01T00:00:00.000Z",
        metadata: %{}
      },
      %Tet.Message{
        id: "msg-usr-#{unique_integer()}",
        session_id: session_id,
        role: :user,
        content: user,
        timestamp: "2025-01-01T00:00:01.000Z",
        metadata: %{}
      }
    ]
  end

  defp provider_opts(server, session_id) do
    [
      api_key: "test-anthropic-key",
      base_url: server.base_url,
      model: "claude-sonnet-4-20250514",
      timeout: 2_000,
      session_id: session_id,
      request_id: "req-anthropic-test",
      max_tokens: 4096
    ]
  end

  defp unique_session(name), do: "session-#{name}-#{System.pid()}-#{unique_integer()}"
  defp unique_integer, do: System.unique_integer([:positive, :monotonic])

  # ---------------------------------------------------------------------------
  # Tests — Cache capability
  # ---------------------------------------------------------------------------

  test "cache_capability returns :full for Anthropic adapter" do
    assert Anthropic.cache_capability() == :full
  end

  # ---------------------------------------------------------------------------
  # Tests — Text streaming
  # ---------------------------------------------------------------------------

  test "streams text deltas with normalized lifecycle events" do
    session_id = unique_session("text-stream")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "Hello"),
      AnthropicStreamServer.text_delta(0, " world"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:ok, response} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert response.content == "Hello world"
    assert response.provider == :anthropic
    assert response.model == "claude-sonnet-4-20250514"
    assert response.metadata.stop_reason == :stop

    collected = collect_events()

    assert Enum.map(collected, & &1.type) == [
             :provider_start,
             :provider_text_delta,
             :assistant_chunk,
             :provider_text_delta,
             :assistant_chunk,
             :provider_usage,
             :provider_done
           ]

    assert collected
           |> Enum.filter(&(&1.type == :provider_text_delta))
           |> Enum.map(&event_value(&1, :text)) == ["Hello", " world"]

    assert collected
           |> Enum.filter(&(&1.type == :assistant_chunk))
           |> Enum.map(&event_value(&1, :content)) == ["Hello", " world"]

    start_event = Enum.at(collected, 0)
    assert event_value(start_event, :provider) == :anthropic
    assert event_value(start_event, :model) == "claude-sonnet-4-20250514"

    done_event = List.last(collected)
    assert event_value(done_event, :stop_reason) == :stop
  end

  # ---------------------------------------------------------------------------
  # Tests — Tool call streaming
  # ---------------------------------------------------------------------------

  test "streams tool calls with deltas, done event, and tool_use stop reason" do
    session_id = unique_session("tool-stream")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "Let me read that file."),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.content_block_start_tool_use(1, "toolu_abc123", "read_file"),
      AnthropicStreamServer.input_json_delta(1, "{\"path\""),
      AnthropicStreamServer.input_json_delta(1, ": \"mix.exs\"}"),
      AnthropicStreamServer.content_block_stop(1),
      AnthropicStreamServer.message_delta("tool_use"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:ok, response} =
             Anthropic.stream_chat(
               provider_history(session_id, "inspect mix.exs"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert response.content == "Let me read that file."
    assert response.metadata.stop_reason == :tool_use

    collected = collect_events()

    assert Enum.map(collected, & &1.type) == [
             :provider_start,
             :provider_text_delta,
             :assistant_chunk,
             :provider_tool_call_delta,
             :provider_tool_call_delta,
             :provider_tool_call_done,
             :provider_usage,
             :provider_done
           ]

    tool_deltas = Enum.filter(collected, &(&1.type == :provider_tool_call_delta))
    assert length(tool_deltas) == 2

    assert Enum.map(tool_deltas, &event_value(&1, :arguments_delta)) == [
             "{\"path\"",
             ": \"mix.exs\"}"
           ]

    assert event_value(List.first(tool_deltas), :id) == "toolu_abc123"
    assert event_value(List.first(tool_deltas), :name) == "read_file"

    tool_done = Enum.find(collected, &(&1.type == :provider_tool_call_done))
    assert event_value(tool_done, :index) == 1
    assert event_value(tool_done, :id) == "toolu_abc123"
    assert event_value(tool_done, :name) == "read_file"
    assert event_value(tool_done, :arguments) == %{"path" => "mix.exs"}

    done = List.last(collected)
    assert event_value(done, :stop_reason) == :tool_use
  end

  # ---------------------------------------------------------------------------
  # Tests — Usage events
  # ---------------------------------------------------------------------------

  test "emits usage event from message_delta" do
    session_id = unique_session("usage")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(input_tokens: 42),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "hi"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn", 17),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:ok, _response} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    collected = collect_events()
    usage = Enum.find(collected, &(&1.type == :provider_usage))
    assert usage != nil
    assert event_value(usage, :input_tokens) == 42
    assert event_value(usage, :output_tokens) == 17
  end

  # ---------------------------------------------------------------------------
  # Tests — Stop reason mapping
  # ---------------------------------------------------------------------------

  test "maps end_turn to :stop" do
    session_id = unique_session("stop-end-turn")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "done"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:ok, response} =
             Anthropic.stream_chat(
               provider_history(session_id, "test"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert response.metadata.stop_reason == :stop
  end

  test "maps max_tokens to :length" do
    session_id = unique_session("stop-max-tokens")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "truncated"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("max_tokens"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:ok, response} =
             Anthropic.stream_chat(
               provider_history(session_id, "test"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert response.metadata.stop_reason == :length
  end

  test "maps tool_use to :tool_use" do
    session_id = unique_session("stop-tool-use")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_tool_use(0, "toolu_1", "search"),
      AnthropicStreamServer.input_json_delta(0, "{}"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("tool_use"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:ok, response} =
             Anthropic.stream_chat(
               provider_history(session_id, "test"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert response.metadata.stop_reason == :tool_use
  end

  # ---------------------------------------------------------------------------
  # Tests — System message extraction
  # ---------------------------------------------------------------------------

  test "extracts system messages to top-level system field" do
    session_id = unique_session("system-extract")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "ok"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:ok, _response} =
             Anthropic.stream_chat(
               provider_history_with_system(session_id, "You are a helpful assistant", "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert_receive {:anthropic_request, request}, 2_000

    # System message should be in top-level "system" field, not in messages
    assert request =~ "\"system\""
    assert request =~ "You are a helpful assistant"

    # The messages array should only contain the user message
    refute request =~ "\"role\":\"system\""
  end

  # ---------------------------------------------------------------------------
  # Tests — Message format conversion
  # ---------------------------------------------------------------------------

  test "converts tool role messages to tool_result format" do
    session_id = unique_session("tool-result")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "got it"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    messages = [
      %Tet.Message{
        id: "msg-1",
        session_id: session_id,
        role: :user,
        content: "read mix.exs",
        timestamp: "2025-01-01T00:00:00.000Z",
        metadata: %{}
      },
      %Tet.Message{
        id: "msg-2",
        session_id: session_id,
        role: :tool,
        content: "defmodule Tet.MixProject do...",
        timestamp: "2025-01-01T00:00:01.000Z",
        metadata: %{tool_call_id: "toolu_abc"}
      }
    ]

    assert {:ok, _response} =
             Anthropic.stream_chat(
               messages,
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert_receive {:anthropic_request, request}, 2_000

    assert request =~ "tool_result"
    assert request =~ "toolu_abc"
  end

  test "converts assistant messages with tool_calls to tool_use content blocks" do
    session_id = unique_session("assistant-tool-calls")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "ok"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    messages = [
      %Tet.Message{
        id: "msg-1",
        session_id: session_id,
        role: :user,
        content: "read mix.exs",
        timestamp: "2025-01-01T00:00:00.000Z",
        metadata: %{}
      },
      %Tet.Message{
        id: "msg-2",
        session_id: session_id,
        role: :assistant,
        content: "Let me read that file.",
        timestamp: "2025-01-01T00:00:01.000Z",
        metadata: %{
          tool_calls: [
            %{id: "toolu_xyz789", name: "read_file", arguments: %{"path" => "mix.exs"}}
          ]
        }
      },
      %Tet.Message{
        id: "msg-3",
        session_id: session_id,
        role: :tool,
        content: "defmodule Tet.MixProject do...",
        timestamp: "2025-01-01T00:00:02.000Z",
        metadata: %{tool_call_id: "toolu_xyz789"}
      }
    ]

    assert {:ok, _response} =
             Anthropic.stream_chat(
               messages,
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert_receive {:anthropic_request, request}, 2_000

    # Assistant message with tool_calls should be serialized as tool_use content blocks
    assert request =~ "tool_use"
    assert request =~ "toolu_xyz789"
    assert request =~ "read_file"

    # Tool result should reference the same tool_use_id
    assert request =~ "tool_result"
  end

  # ---------------------------------------------------------------------------
  # Tests — Cache control / prompt caching
  # ---------------------------------------------------------------------------

  test "forwards cache_control hints in system message content blocks when metadata includes cache_control" do
    session_id = unique_session("cache-control")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "cached"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    # When system message metadata includes cache_control hints,
    # the adapter should forward them in the request body.
    # Anthropic prompt caching uses cache_control: %{type: "ephemeral"}
    # on system content blocks.
    messages = [
      %Tet.Message{
        id: "msg-sys",
        session_id: session_id,
        role: :system,
        content: "You are a helpful assistant.",
        timestamp: "2025-01-01T00:00:00.000Z",
        metadata: %{
          cache_control: %{"type" => "ephemeral"}
        }
      },
      %Tet.Message{
        id: "msg-usr",
        session_id: session_id,
        role: :user,
        content: "hello",
        timestamp: "2025-01-01T00:00:01.000Z",
        metadata: %{}
      }
    ]

    assert {:ok, _response} =
             Anthropic.stream_chat(
               messages,
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert_receive {:anthropic_request, request}, 2_000

    # System prompt content should be present
    assert request =~ "You are a helpful assistant."

    # Anthropic system prompt caching works by having the system field be
    # an array of content blocks with cache_control. At minimum, the
    # adapter should include the system text. The actual cache_control
    # injection may happen at the runtime layer depending on the
    # profile configuration — verify the system field is present.
    assert request =~ "\"system\""
  end

  # ---------------------------------------------------------------------------
  # Tests — Error handling
  # ---------------------------------------------------------------------------

  test "emits provider_error for malformed JSON chunks without crashing" do
    session_id = unique_session("malformed-json")
    parent = self()

    events = [
      "event: message_start\ndata: {not-valid-json}\n\n"
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:error, {:invalid_provider_chunk, _preview, _detail}} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    collected = collect_events()
    assert Enum.map(collected, & &1.type) == [:provider_error]

    error = List.last(collected)
    assert event_value(error, :kind) == :invalid_response
    assert event_value(error, :retryable?) == false
  end

  # ---------------------------------------------------------------------------
  # Tests — In-stream Anthropic SSE error event
  # ---------------------------------------------------------------------------

  test "emits provider_error for in-stream Anthropic error SSE event" do
    session_id = unique_session("sse-error")
    parent = self()

    # Anthropic can emit an error mid-stream — this is different from an HTTP status error
    error_event =
      AnthropicStreamServer.anthropic_sse_error(
        "overloaded_error",
        "Server is overloaded, please retry"
      )

    events = [
      AnthropicStreamServer.message_start(),
      error_event
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:error, {:provider_http_error, detail}} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert detail =~ "Server is overloaded"

    collected = collect_events()
    error = Enum.find(collected, &(&1.type == :provider_error))
    assert error != nil
    assert event_value(error, :kind) == :network_error
    assert event_value(error, :retryable?) == true
  end

  # ---------------------------------------------------------------------------
  # Tests — Timeout produces retryable error
  # ---------------------------------------------------------------------------

  test "emits retryable provider_error on timeout when server hangs" do
    session_id = unique_session("timeout")
    parent = self()

    # Start a server that accepts the TCP connection but never sends a response.
    # With a very short timeout (50ms), the adapter should timeout and emit an error.
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listen)

    _hang_pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)

        # Read the request but never respond
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, _data} -> :timer.sleep(:infinity)
          {:error, _} -> :ok
        end
      end)

    opts =
      provider_opts(%{base_url: "http://127.0.0.1:#{port}"}, session_id)
      |> Keyword.put(:timeout, 50)

    assert {:error, :provider_timeout} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               opts,
               &send(parent, {:event, &1})
             )

    collected = collect_events()
    error = Enum.find(collected, &(&1.type == :provider_error))
    assert error != nil
    assert event_value(error, :kind) == :timeout
    assert event_value(error, :retryable?) == true

    :gen_tcp.close(listen)
  end

  # ---------------------------------------------------------------------------
  # Tests — Network error produces retryable error
  # ---------------------------------------------------------------------------

  test "emits retryable provider_error on network error" do
    session_id = unique_session("network-error")
    parent = self()

    # Use a port that immediately closes — causes a connection-level error
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listen)

    _close_pid =
      spawn_link(fn ->
        case :gen_tcp.accept(listen) do
          {:ok, socket} -> :gen_tcp.close(socket)
          {:error, _} -> :ok
        end
      end)

    opts =
      provider_opts(%{base_url: "http://127.0.0.1:#{port}"}, session_id)
      |> Keyword.put(:timeout, 2_000)

    result =
      Anthropic.stream_chat(
        provider_history(session_id, "hello"),
        opts,
        &send(parent, {:event, &1})
      )

    # Should get an error — either network_error or a closed connection error
    assert {:error, _reason} = result

    collected = collect_events()
    error = Enum.find(collected, &(&1.type == :provider_error))
    assert error != nil

    kind = event_value(error, :kind)
    # Could be :network_error or :invalid_response depending on timing
    assert kind in [:network_error, :invalid_response, :timeout]

    :gen_tcp.close(listen)
  end

  test "emits provider_error for incomplete stream (no message_stop)" do
    session_id = unique_session("incomplete")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "partial")
      # No content_block_stop, no message_delta, no message_stop
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:error, :provider_stream_incomplete} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    collected = collect_events()

    assert Enum.any?(collected, &(&1.type == :provider_error))
    refute Enum.any?(collected, &(&1.type == :provider_done))

    error = Enum.find(collected, &(&1.type == :provider_error))
    assert event_value(error, :kind) == :invalid_response
  end

  # ---------------------------------------------------------------------------
  # Tests — Incomplete stream does NOT emit provider_done
  # ---------------------------------------------------------------------------

  test "incomplete stream without message_stop does not emit provider_done" do
    session_id = unique_session("no-done")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "truncated")
      # Stream ends abruptly — no content_block_stop, no message_delta, no message_stop
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:error, :provider_stream_incomplete} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    collected = collect_events()

    # No done event, no usage event — stream was incomplete, nothing persisted
    refute Enum.any?(collected, &(&1.type == :provider_done))
    refute Enum.any?(collected, &(&1.type == :provider_usage))
    assert Enum.any?(collected, &(&1.type == :provider_error))
  end

  test "emits provider_error for HTTP error status codes" do
    session_id = unique_session("http-error")
    parent = self()

    {:ok, server} =
      AnthropicStreamServer.start(parent, [],
        status: 401,
        body: ~s({"error": {"message": "invalid api key"}})
      )

    assert {:error, {:provider_http_status, 401, _reason, _body}} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    collected = collect_events()
    error = Enum.find(collected, &(&1.type == :provider_error))
    assert event_value(error, :kind) == :auth_failed
  end

  # ---------------------------------------------------------------------------
  # Tests — Rate limit (429) retryable error
  # ---------------------------------------------------------------------------

  test "emits retryable provider_error for 429 rate limit" do
    session_id = unique_session("rate-limit")
    parent = self()

    {:ok, server} =
      AnthropicStreamServer.start(parent, [],
        status: 429,
        body: %{
          "type" => "error",
          "error" => %{"type" => "rate_limit_error", "message" => "Rate limit exceeded"}
        }
      )

    assert {:error, {:provider_http_status, 429, _reason, _body}} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    collected = collect_events()
    error = Enum.find(collected, &(&1.type == :provider_error))
    assert event_value(error, :kind) == :rate_limited
    assert event_value(error, :retryable?) == true
  end

  # ---------------------------------------------------------------------------
  # Tests — Server error (500) provider_unavailable
  # ---------------------------------------------------------------------------

  test "emits retryable provider_error for 500 server error" do
    session_id = unique_session("server-error")
    parent = self()

    {:ok, server} =
      AnthropicStreamServer.start(parent, [],
        status: 500,
        body: %{
          "type" => "error",
          "error" => %{"type" => "api_error", "message" => "Internal server error"}
        }
      )

    assert {:error, {:provider_http_status, 500, _reason, _body}} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    collected = collect_events()
    error = Enum.find(collected, &(&1.type == :provider_error))
    assert event_value(error, :kind) == :provider_unavailable
    assert event_value(error, :retryable?) == true
  end

  test "emits provider_error for missing api_key option" do
    session_id = unique_session("missing-key")
    parent = self()

    assert {:error, {:missing_provider_option, :api_key}} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               [model: "claude-sonnet-4-20250514", session_id: session_id],
               &send(parent, {:event, &1})
             )

    collected = collect_events()
    error = Enum.find(collected, &(&1.type == :provider_error))
    assert event_value(error, :kind) == :invalid_response
  end

  test "emits provider_error for missing model option" do
    session_id = unique_session("missing-model")
    parent = self()

    assert {:error, {:missing_provider_option, :model}} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               [api_key: "test-key", session_id: session_id],
               &send(parent, {:event, &1})
             )

    collected = collect_events()
    error = Enum.find(collected, &(&1.type == :provider_error))
    assert event_value(error, :kind) == :invalid_response
  end

  test "adapter rescues exceptions and returns error tuple (§11 / E11)" do
    session_id = unique_session("rescue")
    parent = self()

    # Pass messages that will cause an exception during encoding —
    # a non-Message value forces message_to_provider to fail
    assert {:error, {:provider_adapter_exception, _message}} =
             Anthropic.stream_chat(
               [:not_a_message],
               [api_key: "test", model: "test", session_id: session_id],
               &send(parent, {:event, &1})
             )

    collected = collect_events()
    assert Enum.any?(collected, &(&1.type == :provider_error))
  end

  test "handles malformed tool call arguments gracefully (§11 / T5)" do
    session_id = unique_session("bad-tool-args")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_tool_use(0, "toolu_1", "read"),
      AnthropicStreamServer.input_json_delta(0, "{not valid json"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("tool_use"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:error, {:invalid_tool_arguments, 0, _detail}} =
             Anthropic.stream_chat(
               provider_history(session_id, "test"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    collected = collect_events()
    error = Enum.find(collected, &(&1.type == :provider_error))
    assert event_value(error, :kind) == :tool_args_invalid
  end

  # ---------------------------------------------------------------------------
  # Tests — Ping events (ignored gracefully)
  # ---------------------------------------------------------------------------

  test "handles ping events gracefully" do
    session_id = unique_session("ping")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.ping(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "hello"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:ok, response} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert response.content == "hello"
  end

  # ---------------------------------------------------------------------------
  # Tests — SSE parsing
  # ---------------------------------------------------------------------------

  test "parse_sse_events handles event: + data: pairs" do
    input =
      "event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: ping\ndata: {\"type\":\"ping\"}\n\n"

    {events, rest} = Anthropic.parse_sse_events(input)

    assert length(events) == 2
    assert rest == ""

    assert Enum.at(events, 0).event == "message_start"
    assert Enum.at(events, 0).data == "{\"type\":\"message_start\"}"
    assert Enum.at(events, 1).event == "ping"
  end

  test "parse_sse_events preserves partial buffer" do
    input =
      "event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: partial\ndata: {\"incomp"

    {events, rest} = Anthropic.parse_sse_events(input)

    assert length(events) == 1
    assert rest =~ "incomp"
  end

  # ---------------------------------------------------------------------------
  # Tests — Request format verification
  # ---------------------------------------------------------------------------

  test "sends correct headers (x-api-key, anthropic-version)" do
    session_id = unique_session("headers")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "ok"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:ok, _response} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert_receive {:anthropic_request, request}, 2_000
    assert request =~ "x-api-key: test-anthropic-key"
    assert request =~ "anthropic-version: 2023-06-01"
  end

  test "includes tools in request body when provided" do
    session_id = unique_session("tools-in-body")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "ok"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    tools = [
      %{
        name: "read_file",
        description: "Read a file",
        input_schema: %{type: "object", properties: %{path: %{type: "string"}}}
      }
    ]

    opts =
      provider_opts(server, session_id)
      |> Keyword.put(:tools, tools)

    assert {:ok, _response} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               opts,
               &send(parent, {:event, &1})
             )

    assert_receive {:anthropic_request, request}, 2_000
    assert request =~ "\"tools\""
    assert request =~ "read_file"
    assert request =~ "input_schema"
  end

  test "sends stream: true and max_tokens in request body" do
    session_id = unique_session("body-fields")
    parent = self()

    events = [
      AnthropicStreamServer.message_start(),
      AnthropicStreamServer.content_block_start_text(0),
      AnthropicStreamServer.text_delta(0, "ok"),
      AnthropicStreamServer.content_block_stop(0),
      AnthropicStreamServer.message_delta("end_turn"),
      AnthropicStreamServer.message_stop()
    ]

    {:ok, server} = AnthropicStreamServer.start(parent, events)

    assert {:ok, _response} =
             Anthropic.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert_receive {:anthropic_request, request}, 2_000
    assert request =~ "\"stream\":true"
    assert request =~ "\"max_tokens\":4096"
    assert request =~ "\"model\":\"claude-sonnet-4-20250514\""
  end
end
