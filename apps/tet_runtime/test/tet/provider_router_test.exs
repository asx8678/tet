defmodule Tet.ProviderRouterTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.Provider.Router

  test "retryable error from first candidate falls back to next candidate and succeeds" do
    session_id = unique_session("fallback")
    parent = self()

    assert {:ok, response} =
             Router.stream_chat(
               provider_history(session_id, "hello"),
               [
                 session_id: session_id,
                 request_id: "req-fallback",
                 routing_key: routing_key_for(2, 0),
                 max_retries: 0,
                 candidates: [
                   [
                     provider: :mock,
                     model: "mock-bad",
                     error: {:provider_http_status, 503, "Service Unavailable", "nope"}
                   ],
                   [provider: :mock, model: "mock-good", chunks: ["fallback ok"]]
                 ]
               ],
               &send(parent, {:event, &1})
             )

    assert response.content == "fallback ok"
    assert response.provider == :mock
    assert response.model == "mock-good"

    events = collect_events()
    route_events = Enum.filter(events, &route_event?/1)

    assert Enum.map(route_events, & &1.type) == [
             :provider_route_decision,
             :provider_route_attempt,
             :provider_route_error,
             :provider_route_fallback,
             :provider_route_attempt,
             :provider_route_done
           ]

    fallback = Enum.find(route_events, &(&1.type == :provider_route_fallback))
    assert event_value(fallback, :candidate_index) == 0
    assert event_value(fallback, :next_candidate_index) == 1
    assert event_value(fallback, :kind) == :provider_unavailable
    assert event_value(fallback, :retryable?) == true
    assert event_value(fallback, :will_fallback?) == true

    assert events
           |> Enum.filter(&(&1.type == :provider_start))
           |> Enum.map(&event_value(&1, :model)) == ["mock-bad", "mock-good"]

    refute Enum.empty?(Enum.filter(events, &(&1.type == :assistant_chunk)))
  end

  test "retryable errors retry the same candidate before fallback" do
    session_id = unique_session("retry")
    parent = self()

    assert {:ok, response} =
             Router.stream_chat(
               provider_history(session_id, "hello"),
               [
                 session_id: session_id,
                 request_id: "req-retry",
                 routing_key: routing_key_for(2, 0),
                 max_retries: 1,
                 candidates: [
                   [
                     provider: :mock,
                     model: "mock-bad",
                     error: {:provider_http_status, 503, "Service Unavailable", "still nope"}
                   ],
                   [provider: :mock, model: "mock-good", chunks: ["after retry"]]
                 ]
               ],
               &send(parent, {:event, &1})
             )

    assert response.content == "after retry"

    events = collect_events()
    assert Enum.count(events, &(&1.type == :provider_route_retry)) == 1

    bad_attempts =
      events
      |> Enum.filter(
        &(&1.type == :provider_route_attempt and event_value(&1, :candidate_index) == 0)
      )
      |> Enum.map(&event_value(&1, :attempt))

    assert bad_attempts == [1, 2]
    assert Enum.any?(events, &(&1.type == :provider_route_fallback))
  end

  test "non-retryable error stops without fallback" do
    session_id = unique_session("nonretryable")
    parent = self()

    assert {:error, :mock_provider_error} =
             Router.stream_chat(
               provider_history(session_id, "hello"),
               [
                 session_id: session_id,
                 request_id: "req-nonretryable",
                 routing_key: routing_key_for(2, 0),
                 max_retries: 0,
                 candidates: [
                   [provider: :mock, model: "mock-bad", error: :mock_provider_error],
                   [provider: :mock, model: "mock-good", chunks: ["should not happen"]]
                 ]
               ],
               &send(parent, {:event, &1})
             )

    events = collect_events()

    refute Enum.any?(events, &(&1.type == :provider_route_fallback))
    refute Enum.any?(events, &(event_value(&1, :model) == "mock-good"))

    route_error = Enum.find(events, &(&1.type == :provider_route_error))
    assert event_value(route_error, :kind) == :unknown
    assert event_value(route_error, :retryable?) == false
    assert event_value(route_error, :terminal?) == true
    assert event_value(route_error, :will_fallback?) == false
  end

  test "route order is deterministic for a routing key" do
    candidates = [
      [provider: :mock, model: "model-0", chunks: ["zero"]],
      [provider: :mock, model: "model-1", chunks: ["one"]],
      [provider: :mock, model: "model-2", chunks: ["two"]]
    ]

    assert {:ok, first_order} = Router.route_order(candidates, routing_key: "same-key")
    assert {:ok, second_order} = Router.route_order(candidates, routing_key: "same-key")
    assert Enum.map(first_order, & &1.index) == Enum.map(second_order, & &1.index)

    assert Router.start_index(3, []) == 0

    assert Router.start_index(3, routing_key: "same-key") ==
             Router.start_index(3, routing_key: "same-key")

    assert Router.start_index(3, session_id: "session-key") ==
             Router.start_index(3, session_id: "session-key")
  end

  test "telemetry callback receives route attempt stop and error with latency, cost, and tokens" do
    session_id = unique_session("telemetry")
    parent = self()

    assert {:ok, response} =
             Router.stream_chat(
               provider_history(session_id, "hello"),
               [
                 session_id: session_id,
                 request_id: "req-telemetry",
                 routing_key: routing_key_for(2, 0),
                 max_retries: 0,
                 telemetry_emit: fn name, measurements, metadata ->
                   send(parent, {:telemetry, name, measurements, metadata})
                 end,
                 candidates: [
                   [
                     provider: :mock,
                     model: "mock-bad",
                     error: {:provider_http_status, 503, "Service Unavailable", "nope"}
                   ],
                   [
                     provider: :mock,
                     model: "mock-good",
                     chunks: ["metered"],
                     usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5},
                     input_cost_per_token: 0.01,
                     output_cost_per_token: 0.02
                   ]
                 ]
               ],
               &send(parent, {:event, &1})
             )

    assert response.content == "metered"
    _events = collect_events()
    telemetry = collect_telemetry()

    assert Enum.any?(telemetry, &match?({[:tet, :provider, :router, :attempt, :error], _, _}, &1))

    assert {_, stop_measurements, stop_metadata} =
             Enum.find(telemetry, fn {name, _measurements, metadata} ->
               name == [:tet, :provider, :router, :attempt, :stop] and
                 metadata[:model] == "mock-good"
             end)

    assert is_integer(stop_measurements[:duration])
    assert is_integer(stop_measurements[:duration_ms])
    assert stop_measurements[:input_tokens] == 2
    assert stop_measurements[:output_tokens] == 3
    assert stop_measurements[:total_tokens] == 5
    assert stop_measurements[:estimated_cost] == 0.08
    assert stop_metadata[:usage] == %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
    assert stop_metadata[:estimated_cost] == 0.08

    assert Enum.any?(telemetry, &match?({[:tet, :provider, :router, :stop], _, _}, &1))
  end

  defp collect_events(acc \\ []) do
    receive do
      {:event, %Tet.Event{} = event} -> collect_events([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp collect_telemetry(acc \\ []) do
    receive do
      {:telemetry, name, measurements, metadata} ->
        collect_telemetry([{name, measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp route_event?(%Tet.Event{type: type}) do
    type in Tet.Event.provider_route_types()
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

  defp routing_key_for(candidate_count, expected_index) do
    Enum.find_value(1..1_000, fn index ->
      key = "router-test-key-#{index}"
      if Router.start_index(candidate_count, routing_key: key) == expected_index, do: key
    end)
  end

  defp unique_session(name), do: "session-#{name}-#{System.pid()}-#{unique_integer()}"

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
  end
end
