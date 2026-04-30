defmodule Tet.Runtime.Timeline do
  @moduledoc """
  Read-only runtime event timeline API.

  Runtime owns event publication and persistence. This module only exposes the
  public facade operations for querying persisted events and subscribing to live
  runtime fanout topics. CLI and future optional UI adapters should come here via
  `Tet.*`, not poke store files or Registry names directly. Boundaries: boring,
  useful, not haunted.
  """

  alias Tet.Runtime.StoreConfig

  @all_topic :runtime_events

  @doc "Lists runtime events, optionally filtered by session id."
  def list_events(session_id \\ nil, opts \\ []) when is_list(opts) do
    with {:ok, session_id} <- normalize_session_id(session_id),
         {:ok, adapter, store_opts} <- StoreConfig.resolve(opts, [:list_events]) do
      adapter.list_events(session_id, store_opts)
    end
  end

  @doc "Subscribes the caller to all future runtime events."
  def subscribe do
    Tet.EventBus.subscribe(@all_topic)
  end

  @doc "Subscribes the caller to future runtime events for one session."
  def subscribe(session_id) when is_binary(session_id) do
    with {:ok, session_id} <- normalize_session_id(session_id) do
      Tet.EventBus.subscribe({:session, session_id})
    end
  end

  @doc "Runtime-wide live event topic."
  def all_topic, do: @all_topic

  defp normalize_session_id(nil), do: {:ok, nil}

  defp normalize_session_id(session_id) when is_binary(session_id) do
    session_id = String.trim(session_id)

    if session_id == "" do
      {:error, :empty_session_id}
    else
      {:ok, session_id}
    end
  end

  defp normalize_session_id(_session_id), do: {:error, :invalid_session_id}
end
