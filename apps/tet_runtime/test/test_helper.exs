defmodule Tet.Runtime.OpenAIStreamServer do
  @moduledoc false

  def start(parent, chunks, opts \\ []) when is_pid(parent) and is_list(chunks) do
    payloads = Enum.map(chunks, &text_payload/1)
    after_done = opts |> Keyword.get(:after_done, []) |> Enum.map(&text_payload/1)

    opts = Keyword.put(opts, :after_done_payloads, after_done)

    start_payloads(parent, payloads, opts)
  end

  def start_payloads(parent, payloads, opts \\ []) when is_pid(parent) and is_list(payloads) do
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
        send(parent, {:openai_request, request})
        send_response(socket, payloads, opts)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)

    {:ok, %{pid: pid, base_url: "http://127.0.0.1:#{port}/v1"}}
  end

  def text_payload(content) when is_binary(content) do
    %{"choices" => [%{"delta" => %{"content" => content}}]}
  end

  def finish_payload(reason \\ "stop") do
    %{"choices" => [%{"delta" => %{}, "finish_reason" => reason}]}
  end

  def usage_payload(usage) when is_map(usage) do
    %{"choices" => [], "usage" => usage}
  end

  def tool_delta_payload(tool_call) when is_map(tool_call) do
    %{"choices" => [%{"delta" => %{"tool_calls" => [tool_call]}}]}
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

  defp send_response(socket, payloads, opts) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/event-stream\r\n",
      "transfer-encoding: chunked\r\n",
      "connection: close\r\n\r\n"
    ])

    Enum.each(payloads, &send_payload(socket, &1))

    if Keyword.get(opts, :send_done, true) do
      send_chunk(socket, "data: [DONE]\n\n")
    end

    opts
    |> Keyword.get(:after_done_payloads, [])
    |> Enum.each(&send_payload(socket, &1))

    if trailing = Keyword.get(opts, :trailing) do
      send_chunk(socket, trailing)
    end

    :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp send_payload(socket, {:data, payload}) when is_binary(payload) do
    send_chunk(socket, "data: #{payload}\n\n")
  end

  defp send_payload(socket, {:raw, data}) when is_binary(data) do
    send_chunk(socket, data)
  end

  defp send_payload(socket, payload) when is_map(payload) do
    payload = payload |> :json.encode() |> IO.iodata_to_binary()
    send_payload(socket, {:data, payload})
  end

  defp send_payload(socket, payload) when is_binary(payload),
    do: send_payload(socket, {:data, payload})

  defp send_chunk(socket, data) do
    size = data |> byte_size() |> Integer.to_string(16)
    :gen_tcp.send(socket, [size, "\r\n", data, "\r\n"])
  end
end

ExUnit.start()

# Ensure SQLite store is started with a fresh temp DB for runtime tests.
db = Path.join(System.tmp_dir!(), "tet_runtime_test.sqlite")
for ext <- ["", "-shm", "-wal"], do: File.rm(db <> ext)

Application.put_env(:tet_store_sqlite, :database_path, db)
Application.put_env(:tet_store_sqlite, Tet.Store.SQLite.Repo, database: db, pool_size: 1)
{:ok, _} = Application.ensure_all_started(:tet_store_sqlite)
