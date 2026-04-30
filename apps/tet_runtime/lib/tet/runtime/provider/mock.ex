defmodule Tet.Runtime.Provider.Mock do
  @moduledoc """
  Deterministic provider used for tests and local smoke checks.
  """

  @behaviour Tet.Provider

  @impl true
  def stream_chat(messages, opts, emit) when is_list(messages) and is_function(emit, 1) do
    session_id = Keyword.get(opts, :session_id) || last_session_id(messages)
    chunks = chunks(messages, opts)

    Enum.each(chunks, fn chunk ->
      emit.(%Tet.Event{
        type: :assistant_chunk,
        session_id: session_id,
        payload: %{content: chunk, provider: :mock}
      })
    end)

    {:ok, %{content: Enum.join(chunks), provider: :mock, metadata: %{chunks: length(chunks)}}}
  end

  defp chunks(messages, opts) do
    cond do
      is_list(Keyword.get(opts, :chunks)) ->
        Keyword.fetch!(opts, :chunks)

      is_binary(Keyword.get(opts, :response)) ->
        [Keyword.fetch!(opts, :response)]

      true ->
        ["mock", ": ", last_user_content(messages)]
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
