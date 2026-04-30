defmodule Tet.Runtime.StoreConfig do
  @moduledoc """
  Runtime-owned store adapter resolution.

  CLI code must not know where message files live, and chat/session runtime code
  should not each grow its own tiny config parser like gremlins after midnight.
  """

  @all_callbacks [
    :health,
    :save_message,
    :list_messages,
    :list_sessions,
    :fetch_session,
    :save_event,
    :list_events
  ]

  @doc "Resolves the configured store adapter and normalized store opts."
  def resolve(opts \\ [], required_callbacks \\ @all_callbacks) when is_list(opts) do
    adapter = adapter(opts)

    cond do
      is_nil(adapter) ->
        {:error, :store_not_configured}

      not Code.ensure_loaded?(adapter) ->
        {:error, {:store_adapter_unavailable, adapter}}

      true ->
        case missing_callbacks(adapter, required_callbacks) do
          [] -> {:ok, adapter, store_opts(opts)}
          missing -> {:error, {:store_adapter_missing_callbacks, adapter, missing}}
        end
    end
  end

  @doc "Returns a store health report through the configured adapter."
  def health(opts \\ []) when is_list(opts) do
    with {:ok, adapter, store_opts} <- resolve(opts, [:health]) do
      adapter.health(store_opts)
    end
  end

  @doc "Returns the configured store adapter module, if any."
  def adapter(opts \\ []) when is_list(opts) do
    Keyword.get(opts, :store_adapter, Application.get_env(:tet_runtime, :store_adapter))
  end

  @doc "Returns normalized store adapter options."
  def store_opts(opts \\ []) when is_list(opts) do
    []
    |> maybe_put(:path, path(opts))
    |> maybe_put(:events_path, events_path(opts))
  end

  @doc "Returns the effective store path from opts, environment, or app config."
  def path(opts \\ []) when is_list(opts) do
    Keyword.get(opts, :store_path) ||
      Keyword.get(opts, :path) ||
      System.get_env("TET_STORE_PATH") ||
      Application.get_env(:tet_runtime, :store_path)
  end

  @doc "Returns the effective event-log path override, if one is configured."
  def events_path(opts \\ []) when is_list(opts) do
    Keyword.get(opts, :events_path) ||
      Keyword.get(opts, :event_path) ||
      System.get_env("TET_EVENTS_PATH") ||
      Application.get_env(:tet_runtime, :events_path)
  end

  defp missing_callbacks(adapter, callbacks) do
    missing =
      callbacks
      |> Enum.reject(&callback_exported?(adapter, &1))

    missing
  end

  defp callback_exported?(adapter, :health), do: function_exported?(adapter, :health, 1)

  defp callback_exported?(adapter, :save_message),
    do: function_exported?(adapter, :save_message, 2)

  defp callback_exported?(adapter, :list_messages),
    do: function_exported?(adapter, :list_messages, 2)

  defp callback_exported?(adapter, :list_sessions),
    do: function_exported?(adapter, :list_sessions, 1)

  defp callback_exported?(adapter, :fetch_session),
    do: function_exported?(adapter, :fetch_session, 2)

  defp callback_exported?(adapter, :save_event), do: function_exported?(adapter, :save_event, 2)

  defp callback_exported?(adapter, :list_events), do: function_exported?(adapter, :list_events, 2)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
