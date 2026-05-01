defmodule Tet.Runtime.Timeline do
  @moduledoc """
  Read-only runtime event timeline API.

  ## Live EventBus vs persisted audit

  Runtime uses two event mechanisms with distinct concerns:

  1. **Live EventBus** (`Tet.EventBus`) — in-process pub/sub fanout for
     real-time subscribers (CLI progress renderers, optional UI adapters, test
     assertions). Events are delivered immediately to subscribing processes but
     are NOT durable. If no subscriber is listening, the event is silently
     dropped. The EventBus is backed by Elixir `Registry` and lives only as long
     as the runtime process.

  2. **Persisted audit / Event store** — events are also persisted through the
     configured store adapter (`StoreConfig`) for durability, query, and replay.
     This happens in `Chat.emit_event/4` and Timeline query functions read from
     the store. Persistence is out of scope for BD-0018; the store adapter
     contract is defined by `Tet.Store.Adapter` behaviour and can be backed by
     SQLite (via `tet_store_sqlite`), PostgreSQL, or any other adapter.

  This module only exposes the public facade operations for querying persisted
  events and subscribing to live runtime fanout topics. CLI and future optional
  UI adapters should come here via `Tet.*`, not poke store files or Registry
  names directly. Boundaries: boring, useful, not haunted.
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
