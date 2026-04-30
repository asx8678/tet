defmodule Tet.Runtime.Chat do
  @moduledoc """
  Session-level chat orchestration for the standalone runtime.

  The CLI supplies a prompt and an event callback. Runtime owns provider
  selection, message persistence, event publication, and session ids.
  """

  alias Tet.Runtime.{Ids, ProviderConfig, StoreConfig}

  @doc "Runs one prompt turn, streams assistant chunks, and persists both messages."
  def ask(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    prompt = String.trim(prompt)

    with :ok <- validate_prompt(prompt),
         {:ok, {provider, provider_opts}} <- ProviderConfig.resolve(opts),
         {:ok, store_adapter, store_opts} <-
           StoreConfig.resolve(opts, [:save_message, :list_messages, :save_event]) do
      session_id = Keyword.get(opts, :session_id) || Ids.session_id()
      emit = Keyword.get(opts, :on_event, fn _event -> :ok end)
      emit_event = &emit_event(session_id, store_adapter, store_opts, emit, &1)

      with {:ok, user_message} <- build_message(:user, prompt, session_id),
           {:ok, user_message} <-
             save_message(store_adapter, user_message, store_opts, emit_event),
           {:ok, history} <- list_messages(store_adapter, session_id, store_opts),
           provider_opts <- Keyword.put(provider_opts, :session_id, session_id),
           {:ok, response} <- provider.stream_chat(history, provider_opts, emit_event),
           {:ok, assistant_message} <- build_message(:assistant, response.content, session_id),
           {:ok, assistant_message} <-
             save_message(store_adapter, assistant_message, store_opts, emit_event) do
        {:ok,
         %{
           session_id: session_id,
           provider: response.provider,
           model: Map.get(response, :model),
           user_message: user_message,
           assistant_message: assistant_message,
           content: assistant_message.content
         }}
      end
    end
  end

  @doc "Lists persisted messages for a session through the configured store."
  def list_messages(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    with {:ok, store_adapter, store_opts} <- StoreConfig.resolve(opts, [:list_messages]) do
      list_messages(store_adapter, session_id, store_opts)
    end
  end

  defp validate_prompt(""), do: {:error, :empty_prompt}
  defp validate_prompt(_prompt), do: :ok

  defp build_message(role, content, session_id) do
    Tet.Message.new(%{
      id: Ids.message_id(),
      session_id: session_id,
      role: role,
      content: content,
      timestamp: Ids.timestamp()
    })
  end

  defp save_message(adapter, message, store_opts, emit) do
    case adapter.save_message(message, store_opts) do
      {:ok, saved} ->
        emit.(%Tet.Event{
          type: :message_persisted,
          session_id: saved.session_id,
          payload: %{message_id: saved.id, role: saved.role}
        })

        {:ok, saved}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_messages(adapter, session_id, store_opts) do
    adapter.list_messages(session_id, store_opts)
  end

  defp emit_event(session_id, adapter, store_opts, emit, %Tet.Event{} = event) do
    event =
      event
      |> ensure_session_id(session_id)
      |> ensure_timestamp()
      |> persist_event(adapter, store_opts)

    publish(event)
    emit.(event)
    :ok
  end

  defp ensure_session_id(%Tet.Event{session_id: nil} = event, session_id) do
    %Tet.Event{event | session_id: session_id}
  end

  defp ensure_session_id(event, _session_id), do: event

  defp ensure_timestamp(%Tet.Event{metadata: metadata} = event) do
    if Map.has_key?(metadata, :timestamp) or Map.has_key?(metadata, "timestamp") do
      event
    else
      %Tet.Event{event | metadata: Map.put(metadata, :timestamp, Ids.timestamp())}
    end
  end

  defp persist_event(%Tet.Event{} = event, adapter, store_opts) do
    case adapter.save_event(event, store_opts) do
      {:ok, saved_event} -> saved_event
      {:error, _reason} -> event
    end
  end

  defp publish(%Tet.Event{} = event) do
    Tet.EventBus.publish(Tet.Runtime.Timeline.all_topic(), event)

    case event.session_id do
      session_id when is_binary(session_id) -> Tet.EventBus.publish({:session, session_id}, event)
      _session_id -> :ok
    end
  end
end
