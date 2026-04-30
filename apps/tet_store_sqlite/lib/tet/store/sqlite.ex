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
  @default_events_path ".tet/events.jsonl"

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
    directory = Path.dirname(path)
    directory_existed? = File.dir?(directory)

    result =
      with :ok <- File.mkdir_p(directory),
           :ok <- assert_readable(path),
           :ok <- assert_writable(directory) do
        {:ok,
         boundary()
         |> Map.merge(%{
           path: path,
           directory: directory,
           status: :ok,
           readable?: true,
           writable?: true,
           started?: started?()
         })}
      else
        {:error, reason} -> {:error, {:store_unhealthy, path, reason}}
      end

    cleanup_created_directory(directory, directory_existed?)
    result
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
    with {:ok, messages} <- read_messages(path(opts)) do
      {:ok, Enum.filter(messages, &(&1.session_id == session_id))}
    end
  end

  @impl true
  def list_sessions(opts) when is_list(opts) do
    with {:ok, messages} <- read_messages(path(opts)) do
      sessions =
        messages
        |> Enum.group_by(& &1.session_id)
        |> Enum.map(fn {session_id, session_messages} ->
          {:ok, session} = Tet.Session.from_messages(session_id, session_messages)
          session
        end)
        |> Enum.sort(&session_newer_or_equal?/2)

      {:ok, sessions}
    end
  end

  @impl true
  def fetch_session(session_id, opts) when is_binary(session_id) and is_list(opts) do
    with {:ok, messages} <- list_messages(session_id, opts) do
      Tet.Session.from_messages(session_id, messages)
    end
  end

  @impl true
  def save_event(%Tet.Event{} = event, opts) when is_list(opts) do
    path = events_path(opts)

    with {:ok, event} <- assign_event_sequence(event, path),
         line = event |> Tet.Event.to_map() |> encode_json!(),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, [line, "\n"], [:append]) do
      {:ok, event}
    end
  end

  @impl true
  def list_events(session_id, opts)
      when (is_binary(session_id) or is_nil(session_id)) and is_list(opts) do
    with {:ok, events} <- read_events(events_path(opts)) do
      {:ok, Enum.filter(events, &event_matches_session?(&1, session_id))}
    end
  end

  defp read_messages(path) do
    read_json_lines(path, &Tet.Message.from_map/1)
  end

  defp read_events(path) do
    read_json_lines(path, &Tet.Event.from_map/1)
  end

  defp read_json_lines(path, decoder) do
    if File.exists?(path) do
      path
      |> File.stream!([], :line)
      |> Enum.reduce_while({:ok, []}, fn line, acc -> decode_line(line, acc, decoder) end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, []}
    end
  rescue
    exception in File.Error -> {:error, {:store_read_failed, exception.reason}}
  end

  defp decode_line(_line, {:error, reason}, _decoder), do: {:halt, {:error, reason}}

  defp decode_line(line, {:ok, records}, decoder) do
    line = String.trim(line)

    cond do
      line == "" ->
        {:cont, {:ok, records}}

      true ->
        with {:ok, decoded} <- decode_json(line),
             :ok <- ensure_record_map(decoded),
             {:ok, record} <- decoder.(decoded) do
          {:cont, {:ok, [record | records]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end
  end

  defp assign_event_sequence(%Tet.Event{sequence: sequence} = event, _path)
       when is_integer(sequence) and sequence >= 0 do
    {:ok, event}
  end

  defp assign_event_sequence(%Tet.Event{} = event, path) do
    with {:ok, events} <- read_events(path) do
      max_sequence =
        events
        |> Enum.map(&(&1.sequence || 0))
        |> Enum.max(fn -> 0 end)

      {:ok, %Tet.Event{event | sequence: max_sequence + 1}}
    end
  end

  defp event_matches_session?(_event, nil), do: true
  defp event_matches_session?(%Tet.Event{session_id: session_id}, session_id), do: true
  defp event_matches_session?(_event, _session_id), do: false

  defp session_newer_or_equal?(left, right) do
    {left.updated_at || "", left.id} >= {right.updated_at || "", right.id}
  end

  defp cleanup_created_directory(_directory, true), do: :ok

  defp cleanup_created_directory(directory, false) do
    File.rmdir(directory)
    :ok
  end

  defp assert_readable(path) do
    if File.exists?(path) do
      case File.open(path, [:read], fn _io -> :ok end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, {:not_readable, reason}}
      end
    else
      :ok
    end
  end

  defp assert_writable(directory) do
    probe_path =
      Path.join(directory, ".tet-health-#{System.unique_integer([:positive, :monotonic])}.tmp")

    result =
      with :ok <- File.write(probe_path, "ok", [:write]),
           {:ok, "ok"} <- File.read(probe_path) do
        :ok
      else
        {:error, reason} -> {:error, {:not_writable, reason}}
        other -> {:error, {:write_probe_failed, other}}
      end

    File.rm(probe_path)
    result
  end

  defp path(opts) do
    Keyword.get(opts, :path) ||
      Keyword.get(opts, :store_path) ||
      System.get_env("TET_STORE_PATH") ||
      Application.get_env(:tet_runtime, :store_path, @default_path)
  end

  defp events_path(opts) do
    Keyword.get(opts, :events_path) ||
      Keyword.get(opts, :event_path) ||
      System.get_env("TET_EVENTS_PATH") ||
      Application.get_env(:tet_runtime, :events_path) ||
      derive_events_path(path(opts))
  end

  defp derive_events_path(@default_path), do: @default_events_path

  defp derive_events_path(message_path) do
    extension = Path.extname(message_path)

    if extension == "" do
      message_path <> ".events.jsonl"
    else
      Path.rootname(message_path) <> ".events" <> extension
    end
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
