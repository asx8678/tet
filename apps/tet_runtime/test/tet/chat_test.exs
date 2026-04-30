defmodule Tet.ChatTest do
  use ExUnit.Case, async: false

  test "mock provider streams chunks and persists user and assistant messages" do
    path = tmp_path("mock")
    session_id = "session-mock"
    parent = self()

    assert {:ok, result} =
             Tet.ask("hello puppy",
               provider: :mock,
               store_path: path,
               session_id: session_id,
               on_event: &send(parent, {:event, &1})
             )

    assert result.session_id == session_id
    assert result.provider == :mock
    assert result.assistant_message.content == "mock: hello puppy"

    assert assistant_chunks() == ["mock", ": ", "hello puppy"]

    assert {:ok, [user_message, assistant_message]} =
             Tet.list_messages(session_id, store_path: path)

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

  test "openai-compatible provider validation rejects missing API key env" do
    without_env("TET_OPENAI_API_KEY", fn ->
      assert {:error, {:missing_provider_env, "TET_OPENAI_API_KEY"}} =
               Tet.ask("hello", provider: :openai_compatible, store_path: tmp_path("missing-env"))
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

  test "configured openai-compatible provider streams SSE chunks and persists messages" do
    path = tmp_path("openai")
    session_id = "session-openai"
    parent = self()
    {:ok, server} = start_openai_stream_server(["configured", " provider"])

    assert {:ok, result} =
             Tet.ask("configured ping",
               provider: :openai_compatible,
               api_key: "test-key",
               base_url: server.base_url,
               model: "unit-test-model",
               store_path: path,
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
             Tet.list_messages(session_id, store_path: path)

    assert user_message.role == :user
    assert user_message.content == "configured ping"
    assert assistant_message.role == :assistant
    assert assistant_message.content == "configured provider"
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

  defp tmp_path(name) do
    root = Path.join(System.tmp_dir!(), "tet-chat-test-#{System.unique_integer([:positive])}")
    Path.join(root, "#{name}.jsonl")
  end

  defp without_env(name, fun) do
    with_env(%{name => nil}, fun)
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
      Enum.each(old_values, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp start_openai_stream_server(chunks) do
    parent = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, request} = recv_request(socket, "")
        send(parent, {:openai_request, request})
        send_response(socket, chunks)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)

    {:ok, %{pid: pid, base_url: "http://127.0.0.1:#{port}/v1"}}
  end

  defp recv_request(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
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

  defp send_response(socket, chunks) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/event-stream\r\n",
      "transfer-encoding: chunked\r\n",
      "connection: close\r\n\r\n"
    ])

    Enum.each(chunks, fn chunk ->
      send_chunk(socket, "data: #{json_chunk(chunk)}\n\n")
    end)

    send_chunk(socket, "data: [DONE]\n\n")
    :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp send_chunk(socket, data) do
    size = data |> byte_size() |> Integer.to_string(16)
    :gen_tcp.send(socket, [size, "\r\n", data, "\r\n"])
  end

  defp json_chunk(content) do
    %{"choices" => [%{"delta" => %{"content" => content}}]}
    |> :json.encode()
    |> IO.iodata_to_binary()
  end
end
