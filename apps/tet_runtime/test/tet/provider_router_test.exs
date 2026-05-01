defmodule Tet.ProviderRouterTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.ProviderConfig
  alias Tet.Runtime.Provider.Router

  defmodule SecretErrorAdapter do
    @behaviour Tet.Provider

    @impl true
    def cache_capability, do: :none

    @impl true
    def stream_chat(_messages, opts, _emit) do
      secret = Keyword.fetch!(opts, :test_secret)

      {:error,
       {:provider_http_status, 503, "Service Unavailable",
        %{
          api_key: secret,
          headers: [authorization: "Bearer #{secret}"],
          nested: {:token, secret},
          body: "api_key=#{secret}"
        }}}
    end
  end

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

  test "config-error candidates are skipped without retry and fall back deterministically" do
    parent = self()
    messages = provider_history(unique_session("config-skip"), "hello")

    for expected_start <- [0, 1] do
      assert {:ok, response} =
               Router.stream_chat(
                 messages,
                 [
                   request_id: "req-config-skip-#{expected_start}",
                   routing_key: routing_key_for(2, expected_start),
                   max_retries: 3,
                   candidates: [
                     [
                       provider: :openai_compatible,
                       model: "needs-env",
                       config_error: {:missing_provider_env, "TET_OPENAI_API_KEY"}
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

      assert Enum.count(route_events, &(&1.type == :provider_route_error)) == 1
      assert Enum.count(route_events, &(&1.type == :provider_route_fallback)) == 1
      assert Enum.count(route_events, &(&1.type == :provider_route_attempt)) == 1
      refute Enum.any?(route_events, &(&1.type == :provider_route_retry))

      skipped = Enum.find(route_events, &(&1.type == :provider_route_error))
      assert event_value(skipped, :skipped?) == true
      assert event_value(skipped, :retryable?) == false
      assert event_value(skipped, :will_retry?) == false
      assert event_value(skipped, :will_fallback?) == true
      assert event_value(skipped, :kind) == :configuration_error
      assert event_value(skipped, :detail) =~ "TET_OPENAI_API_KEY"

      attempted_models =
        route_events
        |> Enum.filter(&(&1.type == :provider_route_attempt))
        |> Enum.map(&event_value(&1, :model))

      assert attempted_models == ["mock-good"]
    end
  end

  test "all config-error candidates return deterministic sanitized no-viable-candidate error" do
    parent = self()
    secret = "sk-router-secret-12345"

    assert {:error, reason} =
             Router.stream_chat(
               provider_history(unique_session("all-config-error"), "hello"),
               [
                 request_id: "req-all-config-error",
                 telemetry_emit: fn name, measurements, metadata ->
                   send(parent, {:telemetry, name, measurements, metadata})
                 end,
                 candidates: [
                   [
                     provider: :openai_compatible,
                     model: "bad-one",
                     config_error: {:bad_config, %{api_key: secret}}
                   ],
                   [
                     provider: :openai_compatible,
                     model: "bad-two",
                     config_error: {:bad_config, [authorization: "Bearer #{secret}"]}
                   ]
                 ]
               ],
               &send(parent, {:event, &1})
             )

    assert {:provider_candidate_config, {:no_viable_candidates, summaries}} = reason
    assert length(summaries) == 2
    refute inspect(reason) =~ secret

    events = collect_events()
    telemetry = collect_telemetry()

    assert Enum.count(events, &(&1.type == :provider_route_error)) == 3
    refute inspect(events) =~ secret
    refute inspect(telemetry) =~ secret
  end

  test "route events and telemetry redact sensitive adapter error details" do
    parent = self()
    secret = "sk-router-secret-67890"

    assert {:error, {:provider_http_status, 503, "Service Unavailable", _body}} =
             Router.stream_chat(
               provider_history(unique_session("secret-error"), "hello"),
               [
                 request_id: "req-secret-error",
                 max_retries: 0,
                 telemetry_emit: fn name, measurements, metadata ->
                   send(parent, {:telemetry, name, measurements, metadata})
                 end,
                 candidates: [
                   [
                     adapter: SecretErrorAdapter,
                     provider: :mock,
                     model: "secret-model",
                     test_secret: secret
                   ]
                 ]
               ],
               &send(parent, {:event, &1})
             )

    events = collect_events()
    telemetry = collect_telemetry()

    route_error = Enum.find(events, &(&1.type == :provider_route_error))

    assert route_error
    assert Enum.any?(telemetry, &match?({[:tet, :provider, :router, :attempt, :error], _, _}, &1))
    refute event_value(route_error, :detail) =~ "[REDACTED]]"
    refute inspect(events) =~ secret
    refute inspect(telemetry) =~ secret
    assert inspect(events) =~ Tet.Redactor.redacted_value()
    assert inspect(telemetry) =~ Tet.Redactor.redacted_value()
  end

  test "registry chat profile skips missing primary env and uses fallback for any rotation" do
    without_env("TET_OPENAI_API_KEY", fn ->
      assert {:ok, {Router, opts}} = ProviderConfig.resolve(provider: :router, profile: "chat")

      assert [openai, mock] = opts[:candidates]
      assert openai.provider == :openai_compatible
      assert openai.config_error == {:missing_provider_env, "TET_OPENAI_API_KEY"}
      assert mock.provider == :mock
      assert is_nil(Map.get(mock, :config_error))

      for expected_start <- [0, 1] do
        parent = self()

        assert {:ok, response} =
                 Router.stream_chat(
                   provider_history(unique_session("registry-chat"), "hello registry"),
                   opts
                   |> Keyword.put(:request_id, "req-registry-chat-#{expected_start}")
                   |> Keyword.put(:routing_key, routing_key_for(2, expected_start)),
                   &send(parent, {:event, &1})
                 )

        assert response.provider == :mock
        assert response.model == "mock-default"
        assert response.content == "mock: hello registry"

        route_events = collect_events() |> Enum.filter(&route_event?/1)
        assert Enum.any?(route_events, &(&1.type == :provider_route_fallback))
        assert Enum.any?(route_events, &(&1.type == :provider_route_done))

        attempts = Enum.filter(route_events, &(&1.type == :provider_route_attempt))
        assert Enum.map(attempts, &event_value(&1, :provider)) == [:mock]
      end
    end)
  end

  test "router diagnostics report degraded registry profile when primary env is missing" do
    without_env("TET_OPENAI_API_KEY", fn ->
      assert {:ok, report} = ProviderConfig.diagnose(provider: :router, profile: "chat")

      assert report.status == :degraded
      assert report.profile == "chat"
      assert report.candidate_count == 2
      assert report.viable_candidate_count == 1
      assert report.config_error_count == 1
      assert {:candidate_config_errors, [config_error]} = report.reason

      assert config_error.provider == :openai_compatible
      assert config_error.model == "gpt-4o-mini"
      assert config_error.config_error? == true
      assert config_error.config_error_detail =~ "TET_OPENAI_API_KEY"

      mock = Enum.find(report.candidates, &(&1.provider == :mock))
      assert mock.config_error? == false
      refute Map.has_key?(mock, :config_error_detail)
    end)
  end

  test "router diagnostics normalize explicit candidates before reporting viability" do
    assert {:error, report} =
             ProviderConfig.diagnose(provider: :router, candidates: [[provider: :unknown]])

    assert report.status == :error
    assert report.candidate_count == 1
    assert report.viable_candidate_count == 0
    assert report.config_error_count == 1
    assert report.message == "provider router has no viable candidates"
    assert report.detail =~ "no_viable_candidates"

    assert {:no_viable_candidates, [config_error]} = report.reason
    assert config_error.candidate_index == 0
    assert config_error.provider == :unknown
    assert config_error.config_error? == true
    assert config_error.config_error_detail =~ "unknown_provider"
    refute Map.has_key?(config_error, :config_error)
  end

  test "router provider config reports malformed candidate lists without leaking details" do
    secret = "sk-router-malformed-secret-12345"

    malformed_candidates = [
      [{:provider, :mock}, {:api_key, secret}, :definitely_not_a_pair]
    ]

    assert {:error, {:invalid_router_candidate, 0, :invalid_candidate_list}} =
             ProviderConfig.resolve(provider: :router, candidates: malformed_candidates)

    assert {:error, report} =
             ProviderConfig.diagnose(provider: :router, candidates: malformed_candidates)

    assert report.status == :error
    assert report.reason == {:invalid_router_candidate, 0, :invalid_candidate_list}
    assert report.detail =~ "invalid_candidate_list"
    assert report.message == "provider router configuration failed"
    refute inspect(report) =~ secret
  end

  test "router candidate normalization handles unknown and malformed candidates without crashing" do
    assert {:ok, [candidate]} = Router.route_order([[provider: :unknown]], [])
    assert candidate.config_error == {:unknown_provider, :unknown}

    assert {:error, {:invalid_router_candidate, 0, :invalid_candidate_list}} =
             Router.route_order([[:definitely_not_a_pair]], [])

    parent = self()

    assert {:error, {:invalid_router_candidate, 0, :invalid_candidate_list}} =
             Router.stream_chat(
               provider_history(unique_session("malformed-candidate"), "hello"),
               [request_id: "req-malformed-candidate", candidates: [[:definitely_not_a_pair]]],
               &send(parent, {:event, &1})
             )

    route_error =
      collect_events()
      |> Enum.filter(&route_event?/1)
      |> List.first()

    assert route_error.type == :provider_route_error
    assert event_value(route_error, :kind) == :configuration_error
    assert event_value(route_error, :detail) =~ "invalid_candidate_list"
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

  defp without_env(name, fun), do: with_env(%{name => nil}, fun)

  defp with_env(vars, fun) do
    old_values = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    try do
      fun.()
    after
      Enum.each(old_values, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp unique_session(name), do: "session-#{name}-#{System.pid()}-#{unique_integer()}"

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
  end
end
