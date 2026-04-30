defmodule Tet.Runtime.Chat do
  @moduledoc """
  Session-level chat orchestration for the standalone runtime.

  The CLI supplies a prompt and an event callback. Runtime owns provider
  selection, message persistence, event publication, and session ids.
  """

  alias Tet.Runtime.{Ids, ProviderConfig}

  @doc "Runs one prompt turn, streams assistant chunks, and persists both messages."
  def ask(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    prompt = String.trim(prompt)

    with :ok <- validate_prompt(prompt),
         {:ok, {provider, provider_opts}} <- ProviderConfig.resolve(opts),
         {:ok, store_adapter, store_opts} <- resolve_store(opts) do
      session_id = Keyword.get(opts, :session_id) || Ids.session_id()
      emit = Keyword.get(opts, :on_event, fn _event -> :ok end)
      emit_event = &emit_event(session_id, emit, &1)

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
    with {:ok, store_adapter, store_opts} <- resolve_store(opts) do
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

  defp resolve_store(opts) do
    adapter = Keyword.get(opts, :store_adapter, Application.get_env(:tet_runtime, :store_adapter))

    cond do
      is_nil(adapter) ->
        {:error, :store_not_configured}

      Code.ensure_loaded?(adapter) and function_exported?(adapter, :save_message, 2) and
          function_exported?(adapter, :list_messages, 2) ->
        {:ok, adapter, store_opts(opts)}

      true ->
        {:error, {:store_adapter_unavailable, adapter}}
    end
  end

  defp store_opts(opts) do
    path =
      Keyword.get(opts, :store_path) ||
        Keyword.get(opts, :path) ||
        System.get_env("TET_STORE_PATH") ||
        Application.get_env(:tet_runtime, :store_path)

    if path, do: [path: path], else: []
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

  defp emit_event(session_id, emit, %Tet.Event{} = event) do
    event = ensure_session_id(event, session_id)
    publish(event)
    emit.(event)
    :ok
  end

  defp ensure_session_id(%Tet.Event{session_id: nil} = event, session_id) do
    %Tet.Event{event | session_id: session_id}
  end

  defp ensure_session_id(event, _session_id), do: event

  defp publish(%Tet.Event{session_id: session_id} = event) when is_binary(session_id) do
    if Process.whereis(Tet.EventBus.Registry) do
      Tet.EventBus.publish({:session, session_id}, event)
    else
      :ok
    end
  end

  defp publish(_event), do: :ok
end
