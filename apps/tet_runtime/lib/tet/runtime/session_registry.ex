defmodule Tet.Runtime.SessionRegistry do
  @moduledoc """
  Named Registry for active session GenServers.

  Each session is registered under its `session_id` so the runtime can look up
  a running session pid by id without coupling to GenServer naming conventions.

  Registration is performed by the session process itself on init, so
  `Registry.register/3` captures the correct pid (the session GenServer, not
  an external caller). `SessionRegistry.register/2` is intentionally removed;
  use register/1 from within the session process.
  """

  @name Tet.Runtime.SessionRegistry

  @doc "Returns the Registry atom registered in the supervision tree."
  def name, do: @name

  @doc """
  Registers the calling process (the session GenServer) under its session id.

  Called from `Session.init/1` — never from external callers.
  """
  @spec register(binary()) :: :ok | {:error, term()}
  def register(session_id) when is_binary(session_id) do
    Registry.register(@name, session_id, %{pid: self()})
  end

  @doc """
  Unregisters the calling process from the registry.
  Called from Session terminate callback.
  """
  @spec unregister() :: :ok
  def unregister do
    Registry.unregister(@name, self())
    :ok
  end

  @doc "Looks up a running session pid by session id."
  @spec lookup(binary()) :: {:ok, pid()} | {:error, :session_not_found}
  def lookup(session_id) when is_binary(session_id) do
    case Registry.lookup(@name, session_id) do
      [{pid, _meta}] -> {:ok, pid}
      [] -> {:error, :session_not_found}
    end
  end

  @doc "Returns all registered session ids."
  @spec list_sessions() :: [binary()]
  def list_sessions do
    @name
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
    |> Enum.uniq()
  end
end
