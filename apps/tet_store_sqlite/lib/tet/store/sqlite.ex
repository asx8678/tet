defmodule Tet.Store.SQLite do
  @moduledoc """
  Default standalone store boundary.

  This phase keeps the adapter dependency-free and persists chat messages as
  JSON Lines. The app/module name remains the default store boundary reserved by
  the scaffold; a later storage ticket can replace the file format with true
  SQLite without changing callers of `Tet.Store`.
  """

  @behaviour Tet.Store

  @default_path ".tet/messages.jsonl"

  @impl true
  def boundary do
    %{
      application: :tet_store_sqlite,
      adapter: __MODULE__,
      status: :local_jsonl,
      path: @default_path,
      format: :jsonl
    }
  end

  @impl true
  def health(opts) when is_list(opts) do
    path = path(opts)

    {:ok,
     boundary()
     |> Map.put(:path, path)
     |> Map.put(:started?, started?())}
  end

  @impl true
  def save_message(%Tet.Message{} = message, opts) when is_list(opts) do
    path = path(opts)
    line = message |> Tet.Message.to_map() |> encode_json!()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, message}
    end
  end

  @impl true
  def list_messages(session_id, opts) when is_binary(session_id) and is_list(opts) do
    path = path(opts)

    if File.exists?(path) do
      path
      |> File.stream!([], :line)
      |> Enum.reduce_while({:ok, []}, &decode_line(session_id, &1, &2))
      |> case do
        {:ok, messages} -> {:ok, Enum.reverse(messages)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  defp decode_line(_session_id, _line, {:error, reason}), do: {:halt, {:error, reason}}

  defp decode_line(session_id, line, {:ok, messages}) do
    line = String.trim(line)

    cond do
      line == "" ->
        {:cont, {:ok, messages}}

      true ->
        with {:ok, decoded} <- decode_json(line),
             :ok <- ensure_record_map(decoded),
             {:ok, message} <- Tet.Message.from_map(decoded) do
          if message.session_id == session_id do
            {:cont, {:ok, [message | messages]}}
          else
            {:cont, {:ok, messages}}
          end
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end
  end

  defp path(opts) do
    Keyword.get(opts, :path) ||
      Keyword.get(opts, :store_path) ||
      System.get_env("TET_STORE_PATH") ||
      Application.get_env(:tet_runtime, :store_path, @default_path)
  end

  defp encode_json!(term) do
    term
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp decode_json(line) do
    {:ok, :json.decode(line)}
  rescue
    exception -> {:error, {:invalid_store_record, Exception.message(exception)}}
  end

  defp ensure_record_map(record) when is_map(record), do: :ok
  defp ensure_record_map(_record), do: {:error, {:invalid_store_record, :not_a_map}}

  defp started? do
    Enum.any?(Application.started_applications(), fn {application, _description, _version} ->
      application == :tet_store_sqlite
    end)
  end
end
