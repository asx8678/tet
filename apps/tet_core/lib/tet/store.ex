defmodule Tet.Store do
  @moduledoc """
  Store adapter behaviour owned by the core boundary.

  Concrete store applications implement this behaviour. Runtime code selects an
  adapter through configuration and calls it through this contract instead of
  binding UI code or orchestration code to storage internals. The contract owns
  both primary chat messages and autosave checkpoint snapshots.
  """

  @type health :: %{
          required(:application) => atom(),
          required(:adapter) => module(),
          required(:status) => atom(),
          optional(:path) => binary(),
          optional(atom()) => term()
        }

  @callback boundary() :: map()
  @callback health(keyword()) :: {:ok, health()} | {:error, term()}
  @callback save_message(Tet.Message.t(), keyword()) :: {:ok, Tet.Message.t()} | {:error, term()}
  @callback list_messages(binary(), keyword()) :: {:ok, [Tet.Message.t()]} | {:error, term()}
  @callback list_sessions(keyword()) :: {:ok, [Tet.Session.t()]} | {:error, term()}
  @callback fetch_session(binary(), keyword()) :: {:ok, Tet.Session.t()} | {:error, term()}
  @callback save_autosave(Tet.Autosave.t(), keyword()) ::
              {:ok, Tet.Autosave.t()} | {:error, term()}
  @callback load_autosave(binary(), keyword()) :: {:ok, Tet.Autosave.t()} | {:error, term()}
  @callback list_autosaves(keyword()) :: {:ok, [Tet.Autosave.t()]} | {:error, term()}
end
