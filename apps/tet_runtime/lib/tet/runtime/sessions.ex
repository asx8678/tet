defmodule Tet.Runtime.Sessions do
  @moduledoc """
  Runtime session query orchestration.

  Store adapters own persistence mechanics. This module owns the public runtime
  operations for listing and showing persisted sessions without leaking adapter
  details into CLI renderers.
  """

  alias Tet.Runtime.StoreConfig

  @doc "Lists persisted sessions through the configured store."
  def list(opts \\ []) when is_list(opts) do
    with {:ok, adapter, store_opts} <- StoreConfig.resolve(opts, [:list_sessions]) do
      adapter.list_sessions(store_opts)
    end
  end

  @doc "Fetches one session summary and its messages through the configured store."
  def show(session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    session_id = String.trim(session_id)

    with :ok <- validate_session_id(session_id),
         {:ok, adapter, store_opts} <-
           StoreConfig.resolve(opts, [:fetch_session, :list_messages]),
         {:ok, session} <- adapter.fetch_session(session_id, store_opts),
         {:ok, messages} <- adapter.list_messages(session_id, store_opts) do
      {:ok, %{session: session, messages: messages}}
    end
  end

  defp validate_session_id(""), do: {:error, :empty_session_id}
  defp validate_session_id(_session_id), do: :ok
end
