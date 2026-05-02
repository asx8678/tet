defmodule Tet.ChatTest do
  use ExUnit.Case, async: false

  setup do
    # Clean tables for test isolation
    alias Tet.Store.SQLite.Repo

    for table <- ["events", "messages", "autosaves", "sessions", "workspaces"] do
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table}", [])
    end

    old_events_path = System.get_env("TET_EVENTS_PATH")
    System.delete_env("TET_EVENTS_PATH")

    on_exit(fn ->
      restore_env(%{"TET_EVENTS_PATH" => old_events_path})
    end)

    :ok
  end

  test "mock provider streams chunks and persists user and assistant messages" do
    session_id = unique_session("mock")
    parent = self()

    assert {:ok, result} =
             Tet.ask("hello puppy",
               provider: :mock,
               session_id: session_id,
               on_event: &send(parent, {:event, &1})
             )

    assert result.session_id == session_id
    assert result.provider == :mock
    assert result.assistant_message.content == "mock: hello puppy"

    assert assistant_chunks() == ["mock", ": ", "hello puppy"]

    assert {:ok, [user_message, assistant_message]} =
             Tet.list_messages(session_id)

    assert user_message.role == :user
    assert user_message.content == "hello puppy"
    assert user_message.session_id == session_id
    assert is_binary(user_message.id)
    assert is_binary(user_message.timestamp)

    assert assistant_message.role == :assistant
    assert assistant_message.content == "mock: hello puppy"
    assert assistant_message.session_id == session_id
    assert is_binary(assistant_message.id)
    assert is_binary(assistant_message.timestamp)
  end

  test "timeline persists chat events and facade subscription receives runtime fanout" do
    session_id = unique_session("timeline")

    assert {:ok, _subscription} = Tet.subscribe_events(session_id)

    assert {:ok, _result} =
             Tet.ask("timeline please", provider: :mock, session_id: session_id)

    live_events = collect_tet_events(session_id)

    expected_types = [
      :message_persisted,
      :provider_start,
      :provider_text_delta,
      :assistant_chunk,
      :provider_text_delta,
      :assistant_chunk,
      :provider_text_delta,
      :assistant_chunk,
      :provider_done,
      :message_persisted
    ]

    assert Enum.map(live_events, & &1.type) == expected_types

    assert {:ok, events} = Tet.list_events(session_id)

    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..10)

    assert Enum.map(events, & &1.type) == expected_types

    assert Enum.all?(events, &(&1.session_id == session_id))
    assert event_value(List.first(events), :role) == "user"
    assert event_value(List.last(events), :role) == "assistant"

    assert events |> Enum.find(&(&1.type == :provider_start)) |> event_value(:provider) == "mock"

    assert events |> Enum.find(&(&1.type == :provider_done)) |> event_value(:stop_reason) ==
             "stop"

    assert events
           |> Enum.filter(&(&1.type == :provider_text_delta))
           |> Enum.map(&event_value(&1, :text)) == ["mock", ": ", "timeline please"]

    assert events
           |> Enum.filter(&(&1.type == :assistant_chunk))
           |> Enum.map(&event_value(&1, :content)) == ["mock", ": ", "timeline please"]
  end

  test "session resume appends turns under the same session id" do
    session_id = unique_session("resume")

    assert {:ok, first} =
             Tet.ask("first turn", provider: :mock, session_id: session_id)

    assert first.session_id == session_id

    assert {:ok, second} =
             Tet.resume_session(session_id, "second turn", provider: :mock)

    assert second.session_id == session_id

    assert {:ok, [user_1, assistant_1, user_2, assistant_2]} =
             Tet.list_messages(session_id)

    assert Enum.map([user_1, assistant_1, user_2, assistant_2], & &1.role) == [
             :user,
             :assistant,
             :user,
             :assistant
           ]

    assert user_1.content == "first turn"
    assert assistant_1.content == "mock: first turn"
    assert user_2.content == "second turn"
    assert assistant_2.content == "mock: second turn"

    assert {:ok, [session]} = Tet.list_sessions()
    assert session.id == session_id
    assert session.message_count == 4
    assert session.last_role == :assistant
    assert session.last_content == "mock: second turn"

    assert {:ok, %{session: shown, messages: shown_messages}} =
             Tet.show_session(session_id)

    assert shown.id == session_id
    assert length(shown_messages) == 4
  end

  test "ask can compact provider context without mutating persisted session history" do
    session_id = unique_session("ask-compaction")

    assert {:ok, _first} =
             Tet.ask("first compactable turn",
               provider: :mock,
               session_id: session_id
             )

    assert {:ok, _second} =
             Tet.ask("second compactable turn",
               provider: :mock,
               session_id: session_id
             )

    assert {:ok, third} =
             Tet.ask("third compacted turn",
               provider: :mock,
               session_id: session_id,
               compaction: [force: true, recent_count: 2]
             )

    assert third.assistant_message.content == "mock: third compacted turn"
    assert third.compaction["original_message_count"] == 5
    assert third.compaction["retained_message_count"] == 2
    assert third.compaction["compacted_message_count"] == 3

    assert {:ok, messages} = Tet.list_messages(session_id)

    assert Enum.map(messages, & &1.content) == [
             "first compactable turn",
             "mock: first compactable turn",
             "second compactable turn",
             "mock: second compactable turn",
             "third compacted turn",
             "mock: third compacted turn"
           ]
  end

  test "openai-compatible provider validation rejects missing API key env" do
    without_env("TET_OPENAI_API_KEY", fn ->
      assert {:error, {:missing_provider_env, "TET_OPENAI_API_KEY"}} =
               Tet.ask(
                 "hello",
                 provider: :openai_compatible
               )
    end)
  end

  test "openai-compatible provider config reads secrets and model settings from env" do
    with_env(
      %{
        "TET_OPENAI_API_KEY" => "env-key",
        "TET_OPENAI_BASE_URL" => "http://127.0.0.1:9999/custom",
        "TET_OPENAI_MODEL" => "env-model"
      },
      fn ->
        assert {:ok, {Tet.Runtime.Provider.OpenAICompatible, opts}} =
                 Tet.Runtime.ProviderConfig.resolve(provider: :openai_compatible)

        assert opts[:api_key] == "env-key"
        assert opts[:base_url] == "http://127.0.0.1:9999/custom"
        assert opts[:model] == "env-model"
      end
    )
  end

  test "router provider config can build candidates from registry profile" do
    assert {:ok, {Tet.Runtime.Provider.Router, opts}} =
             Tet.Runtime.ProviderConfig.resolve(provider: :router, profile: "tet_standalone")

    assert [candidate] = opts[:candidates]
    assert candidate.provider == :mock
    assert candidate.adapter == Tet.Runtime.Provider.Mock
    assert candidate.model == "mock-default"
    assert candidate.opts[:provider] == :mock
    assert candidate.opts[:model] == "mock-default"
  end

  test "router ask persists route audit events and assistant message" do
    session_id = unique_session("router")
    parent = self()

    assert {:ok, result} =
             Tet.ask("routed ping",
               provider: :router,
               routing_key: router_key_for(2, 0),
               max_retries: 0,
               candidates: [
                 [
                   provider: :mock,
                   model: "mock-bad",
                   error: {:provider_http_status, 503, "Service Unavailable", "nope"}
                 ],
                 [provider: :mock, model: "mock-good", chunks: ["routed answer"]]
               ],
               session_id: session_id,
               on_event: &send(parent, {:event, &1})
             )

    assert result.provider == :mock
    assert result.model == "mock-good"
    assert result.assistant_message.content == "routed answer"
    assert assistant_chunks() == ["routed answer"]

    assert {:ok, [user_message, assistant_message]} =
             Tet.list_messages(session_id)

    assert user_message.role == :user
    assert user_message.content == "routed ping"
    assert assistant_message.role == :assistant
    assert assistant_message.content == "routed answer"

    assert {:ok, events} = Tet.list_events(session_id)
    event_types = Enum.map(events, & &1.type)

    assert :provider_route_decision in event_types
    assert :provider_route_attempt in event_types
    assert :provider_route_error in event_types
    assert :provider_route_fallback in event_types
    assert :provider_route_done in event_types
    assert :message_persisted == List.first(event_types)
    assert :message_persisted == List.last(event_types)

    fallback = Enum.find(events, &(&1.type == :provider_route_fallback))
    assert event_value(fallback, :candidate_index) == 0
    assert event_value(fallback, :next_candidate_index) == 1
    assert event_value(fallback, :kind) == "provider_unavailable"
  end

  test "configured openai-compatible provider streams SSE chunks and persists messages" do
    session_id = unique_session("openai")
    parent = self()
    {:ok, server} = start_openai_stream_server(["configured", " provider"])

    assert {:ok, result} =
             Tet.ask("configured ping",
               provider: :openai_compatible,
               api_key: "test-key",
               base_url: server.base_url,
               model: "unit-test-model",
               session_id: session_id,
               on_event: &send(parent, {:event, &1})
             )

    assert result.provider == :openai_compatible
    assert result.model == "unit-test-model"
    assert result.assistant_message.content == "configured provider"
    assert assistant_chunks() == ["configured", " provider"]

    assert_receive {:openai_request, request}, 1_000
    assert request =~ "POST /v1/chat/completions"
    assert request =~ "authorization: Bearer test-key"
    assert request =~ ~s("stream":true)
    assert request =~ ~s("model":"unit-test-model")
    assert request =~ "configured ping"

    assert {:ok, [user_message, assistant_message]} =
             Tet.list_messages(session_id)

    assert user_message.role == :user
    assert user_message.content == "configured ping"
    assert assistant_message.role == :assistant
    assert assistant_message.content == "configured provider"
  end

  test "direct openai-compatible provider rejects chunks that close without done" do
    session_id = unique_session("provider-incomplete")
    {:ok, server} = start_openai_stream_server(["partial"], send_done: false)

    assert {:error, :provider_stream_incomplete} =
             Tet.Runtime.Provider.OpenAICompatible.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               fn _event -> :ok end
             )

    assert_receive {:openai_request, _request}, 1_000
  end

  test "direct openai-compatible provider rejects missing done even with obsolete option" do
    session_id = unique_session("provider-obsolete-compat")
    {:ok, server} = start_openai_stream_server(["legacy"], send_done: false)

    assert {:error, :provider_stream_incomplete} =
             Tet.Runtime.Provider.OpenAICompatible.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id, allow_incomplete_stream: true),
               fn _event -> :ok end
             )

    assert_receive {:openai_request, _request}, 1_000
  end

  test "provider config does not forward obsolete incomplete-stream option paths" do
    with_app_env(
      :tet_runtime,
      :openai_compatible,
      [allow_incomplete_stream: true],
      fn ->
        assert {:ok, {Tet.Runtime.Provider.OpenAICompatible, opts}} =
                 Tet.Runtime.ProviderConfig.resolve(
                   provider: :openai_compatible,
                   api_key: "test-key",
                   allow_incomplete_stream: true
                 )

        refute Keyword.has_key?(opts, :allow_incomplete_stream)
      end
    )
  end

  test "direct openai-compatible provider rejects content after done" do
    session_id = unique_session("provider-after-done")
    {:ok, server} = start_openai_stream_server(["first"], after_done: ["nope"])

    assert {:error, :provider_stream_incomplete} =
             Tet.Runtime.Provider.OpenAICompatible.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               fn _event -> :ok end
             )

    assert_receive {:openai_request, _request}, 1_000
  end

  test "direct openai-compatible provider rejects a trailing partial SSE buffer" do
    session_id = unique_session("provider-leftover")

    {:ok, server} =
      start_openai_stream_server([], send_done: false, trailing: ~s(data: {"choices"))

    assert {:error, :provider_stream_incomplete} =
             Tet.Runtime.Provider.OpenAICompatible.stream_chat(
               provider_history(session_id, "hello"),
               provider_opts(server, session_id),
               fn _event -> :ok end
             )

    assert_receive {:openai_request, _request}, 1_000
  end

  test "Tet.ask does not persist assistant message when provider stream is incomplete" do
    session_id = unique_session("runtime-incomplete")
    {:ok, server} = start_openai_stream_server(["partial"], send_done: false)

    with_app_env(:tet_runtime, :openai_compatible, [allow_incomplete_stream: true], fn ->
      assert {:error, :provider_stream_incomplete} =
               Tet.ask("please fail safely",
                 provider: :openai_compatible,
                 api_key: "test-key",
                 base_url: server.base_url,
                 model: "unit-test-model",
                 session_id: session_id,
                 allow_incomplete_stream: true
               )

      assert_receive {:openai_request, _request}, 1_000

      assert {:ok, [user_message]} = Tet.list_messages(session_id)
      assert user_message.role == :user
      assert user_message.content == "please fail safely"
      # With SQLite, verify no assistant message via list_messages instead of
      # reading a JSONL file (the Repo-based adapter doesn't write to a file).
      assert {:ok, messages} = Tet.list_messages(session_id)
      refute Enum.any?(messages, &(&1.role == :assistant))
    end)
  end

  test "adapter round-trips unicode content through SQLite without corruption" do
    session_id = unique_session("unicode-robustness")
    unicode_content = "Hello 🐶 世界 café — 'quotes' & <tags>"

    assert {:ok, _result} =
             Tet.ask(unicode_content, provider: :mock, session_id: session_id)

    assert {:ok, [user_msg, _assistant_msg]} = Tet.list_messages(session_id)
    assert user_msg.content == unicode_content

    assert {:ok, events} = Tet.list_events(session_id)
    assert length(events) > 0
    assert Enum.all?(events, &is_binary(&1.session_id))
  end

  defp collect_tet_events(session_id, acc \\ []) do
    receive do
      {:tet_event, {:session, ^session_id}, %Tet.Event{} = event} ->
        collect_tet_events(session_id, [event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp event_value(%Tet.Event{payload: payload}, key) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
  end

  defp assistant_chunks(acc \\ []) do
    receive do
      {:event, %Tet.Event{type: :assistant_chunk, payload: %{content: content}}} ->
        assistant_chunks([content | acc])

      {:event, _event} ->
        assistant_chunks(acc)
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp router_key_for(candidate_count, expected_index) do
    Enum.find_value(1..1_000, fn index ->
      key = "chat-router-key-#{index}"

      if Tet.Runtime.Provider.Router.start_index(candidate_count, routing_key: key) ==
           expected_index,
         do: key
    end)
  end

  defp unique_session(name), do: "session-#{name}-#{System.pid()}-#{unique_integer()}"

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
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

  defp provider_opts(server, session_id, opts \\ []) do
    Keyword.merge(
      [
        api_key: "test-key",
        base_url: server.base_url,
        model: "unit-test-model",
        timeout: 1_000,
        session_id: session_id
      ],
      opts
    )
  end

  defp without_env(name, fun) do
    with_env(%{name => nil}, fun)
  end

  defp with_app_env(app, key, value, fun) do
    old_value = Application.get_env(app, key)

    Application.put_env(app, key, value)

    try do
      fun.()
    after
      if is_nil(old_value) do
        Application.delete_env(app, key)
      else
        Application.put_env(app, key, old_value)
      end
    end
  end

  defp with_env(vars, fun) do
    old_values = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    try do
      fun.()
    after
      restore_env(old_values)
    end
  end

  defp restore_env(vars) do
    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  defp start_openai_stream_server(chunks, opts \\ []) do
    Tet.Runtime.OpenAIStreamServer.start(self(), chunks, opts)
  end
end
