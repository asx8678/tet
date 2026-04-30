defmodule Tet.ProviderStreamingTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.OpenAIStreamServer
  alias Tet.Runtime.Provider.{Mock, OpenAICompatible}

  test "mock provider emits normalized lifecycle events plus assistant chunk compatibility" do
    session_id = unique_session("mock-normalized")
    parent = self()

    assert {:ok, response} =
             Mock.stream_chat(
               provider_history(session_id, "hello"),
               [chunks: ["hi", " pup"], usage: %{input_tokens: 1, output_tokens: 2}],
               &send(parent, {:event, &1})
             )

    assert response.content == "hi pup"
    assert response.provider == :mock

    events = collect_events()

    assert Enum.map(events, & &1.type) == [
             :provider_start,
             :provider_text_delta,
             :assistant_chunk,
             :provider_text_delta,
             :assistant_chunk,
             :provider_usage,
             :provider_done
           ]

    assert events |> Enum.at(0) |> event_value(:provider) == :mock

    assert events
           |> Enum.filter(&(&1.type == :provider_text_delta))
           |> Enum.map(&event_value(&1, :text)) == ["hi", " pup"]

    assert events
           |> Enum.filter(&(&1.type == :assistant_chunk))
           |> Enum.map(&event_value(&1, :content)) == ["hi", " pup"]

    usage = Enum.find(events, &(&1.type == :provider_usage))
    assert event_value(usage, :input_tokens) == 1
    assert event_value(usage, :output_tokens) == 2

    done = Enum.find(events, &(&1.type == :provider_done))
    assert event_value(done, :stop_reason) == :stop
  end

  test "mock provider errors become normalized provider_error events without raising" do
    session_id = unique_session("mock-error")
    parent = self()

    assert {:error, :mock_provider_error} =
             Mock.stream_chat(
               provider_history(session_id, "hello"),
               [error: :mock_provider_error, session_id: session_id],
               &send(parent, {:event, &1})
             )

    events = collect_events()

    assert Enum.map(events, & &1.type) == [:provider_start, :provider_error]

    error = List.last(events)
    assert event_value(error, :kind) == :unknown
    assert event_value(error, :retryable?) == false
    assert event_value(error, :detail) == ":mock_provider_error"
  end

  test "openai-compatible provider normalizes text, tool call, usage, and done SSE fixtures" do
    session_id = unique_session("openai-normalized")
    parent = self()

    {:ok, server} =
      OpenAIStreamServer.start_payloads(parent, [
        OpenAIStreamServer.text_payload("Need a file"),
        OpenAIStreamServer.tool_delta_payload(%{
          "index" => 0,
          "id" => "call_read",
          "function" => %{"name" => "read_file", "arguments" => "{"}
        }),
        OpenAIStreamServer.tool_delta_payload(%{
          "index" => 0,
          "function" => %{"arguments" => "\"path\":\"mix.exs\"}"}
        }),
        OpenAIStreamServer.finish_payload("tool_calls"),
        OpenAIStreamServer.usage_payload(%{
          "prompt_tokens" => 7,
          "completion_tokens" => 11,
          "total_tokens" => 18
        })
      ])

    assert {:ok, response} =
             OpenAICompatible.stream_chat(
               provider_history(session_id, "inspect"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    assert response.content == "Need a file"
    assert response.provider == :openai_compatible
    assert response.model == "unit-test-model"
    assert response.metadata.stop_reason == :tool_use

    events = collect_events()

    assert Enum.map(events, & &1.type) == [
             :provider_start,
             :provider_text_delta,
             :assistant_chunk,
             :provider_tool_call_delta,
             :provider_tool_call_delta,
             :provider_tool_call_done,
             :provider_usage,
             :provider_done
           ]

    start = Enum.at(events, 0)
    assert event_value(start, :provider) == :openai_compatible
    assert event_value(start, :model) == "unit-test-model"

    assert events |> Enum.find(&(&1.type == :provider_text_delta)) |> event_value(:text) ==
             "Need a file"

    tool_deltas = Enum.filter(events, &(&1.type == :provider_tool_call_delta))

    assert Enum.map(tool_deltas, &event_value(&1, :arguments_delta)) == [
             "{",
             "\"path\":\"mix.exs\"}"
           ]

    assert event_value(List.first(tool_deltas), :id) == "call_read"
    assert event_value(List.first(tool_deltas), :name) == "read_file"

    tool_done = Enum.find(events, &(&1.type == :provider_tool_call_done))
    assert event_value(tool_done, :index) == 0
    assert event_value(tool_done, :id) == "call_read"
    assert event_value(tool_done, :name) == "read_file"
    assert event_value(tool_done, :arguments) == %{"path" => "mix.exs"}

    usage = Enum.find(events, &(&1.type == :provider_usage))
    assert event_value(usage, :input_tokens) == 7
    assert event_value(usage, :output_tokens) == 11
    assert event_value(usage, :total_tokens) == 18

    done = List.last(events)
    assert event_value(done, :stop_reason) == :tool_use

    assert_receive {:openai_request, request}, 1_000
    assert request =~ ~s("stream_options":{"include_usage":true})
  end

  test "openai-compatible provider emits provider_error for malformed chunks instead of crashing" do
    session_id = unique_session("openai-malformed")
    parent = self()
    {:ok, server} = OpenAIStreamServer.start_payloads(parent, ["{not-json"])

    assert {:error, {:invalid_provider_chunk, _payload, _detail}} =
             OpenAICompatible.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    events = collect_events()

    assert Enum.map(events, & &1.type) == [:provider_start, :provider_error]

    error = List.last(events)
    assert event_value(error, :kind) == :invalid_response
    assert event_value(error, :retryable?) == false
    assert event_value(error, :detail) =~ ":invalid_provider_chunk"

    assert_receive {:openai_request, _request}, 1_000
  end

  test "openai-compatible provider emits provider_error for malformed JSON shapes" do
    session_id = unique_session("openai-malformed-shape")
    parent = self()

    {:ok, server} =
      OpenAIStreamServer.start_payloads(parent, [%{"choices" => [%{"delta" => "nope"}]}])

    assert {:error, {:invalid_provider_chunk, {:invalid_field, :delta, "nope"}}} =
             OpenAICompatible.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    events = collect_events()

    assert Enum.map(events, & &1.type) == [:provider_start, :provider_error]
    assert events |> List.last() |> event_value(:kind) == :invalid_response

    assert_receive {:openai_request, _request}, 1_000
  end

  test "openai-compatible provider emits provider_error for incomplete streams without provider_done" do
    session_id = unique_session("openai-incomplete")
    parent = self()

    {:ok, server} =
      OpenAIStreamServer.start_payloads(parent, [OpenAIStreamServer.text_payload("partial")],
        send_done: false
      )

    assert {:error, :provider_stream_incomplete} =
             OpenAICompatible.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               &send(parent, {:event, &1})
             )

    events = collect_events()

    assert Enum.map(events, & &1.type) == [
             :provider_start,
             :provider_text_delta,
             :assistant_chunk,
             :provider_error
           ]

    refute Enum.any?(events, &(&1.type == :provider_done))

    error = List.last(events)
    assert event_value(error, :kind) == :invalid_response
    assert event_value(error, :detail) == ":provider_stream_incomplete"

    assert_receive {:openai_request, _request}, 1_000
  end

  defp collect_events(acc \\ []) do
    receive do
      {:event, %Tet.Event{} = event} -> collect_events([event | acc])
    after
      50 -> Enum.reverse(acc)
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

  defp provider_opts(server, session_id) do
    [
      api_key: "test-key",
      base_url: server.base_url,
      model: "unit-test-model",
      timeout: 1_000,
      session_id: session_id,
      request_id: "req-test"
    ]
  end

  defp unique_session(name), do: "session-#{name}-#{System.pid()}-#{unique_integer()}"

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
  end
end
