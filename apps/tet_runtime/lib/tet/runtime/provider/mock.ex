defmodule Tet.Runtime.Provider.Mock do
  @moduledoc """
  Deterministic provider used for tests and local smoke checks.
  """

  @behaviour Tet.Provider

  alias Tet.Runtime.Provider.StreamEvents

  @impl true
  def stream_chat(messages, opts, emit) when is_list(messages) and is_function(emit, 1) do
    opts = Keyword.put_new(opts, :session_id, last_session_id(messages))

    StreamEvents.emit_start(:mock, opts, emit)

    case Keyword.fetch(opts, :error) do
      {:ok, reason} ->
        StreamEvents.emit_error(:mock, reason, opts, emit)
        {:error, reason}

      :error ->
        with {:ok, chunks} <- chunks(messages, opts) do
          Enum.each(chunks, &StreamEvents.emit_text_delta(:mock, &1, opts, emit))
          maybe_emit_usage(opts, emit)
          StreamEvents.emit_done(:mock, :stop, opts, emit)

          {:ok,
           %{content: Enum.join(chunks), provider: :mock, metadata: %{chunks: length(chunks)}}}
        else
          {:error, reason} ->
            StreamEvents.emit_error(:mock, reason, opts, emit)
            {:error, reason}
        end
    end
  end

  defp chunks(messages, opts) do
    chunks =
      cond do
        is_list(Keyword.get(opts, :chunks)) ->
          Keyword.fetch!(opts, :chunks)

        is_binary(Keyword.get(opts, :response)) ->
          [Keyword.fetch!(opts, :response)]

        true ->
          ["mock", ": ", last_user_content(messages)]
      end

    if Enum.all?(chunks, &is_binary/1) do
      {:ok, chunks}
    else
      {:error, {:invalid_mock_chunks, chunks}}
    end
  end

  defp maybe_emit_usage(opts, emit) do
    case Keyword.get(opts, :usage) do
      usage when is_map(usage) -> StreamEvents.emit_usage(:mock, usage, opts, emit)
      _usage -> :ok
    end
  end

  defp last_user_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :user))
    |> case do
      %Tet.Message{content: content} -> content
      _ -> "response"
    end
  end

  defp last_session_id(messages) do
    case List.last(messages) do
      %Tet.Message{session_id: session_id} -> session_id
      _ -> nil
    end
  end
end
