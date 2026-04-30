defmodule Tet.Runtime.SessionRegistry do
  @moduledoc """
  Named Registry for active session GenServers.

  Each session is registered under its `session_id` so the runtime can look up
  a running session pid by id without coupling to GenServer naming conventions.
  """

  @name Tet.Runtime.SessionRegistry

  @doc "Returns the Registry atom registered in the supervision tree."
  def name, do: @name

  @doc "Registers a session pid under its session id."
  @spec register(binary(), pid()) :: :ok | {:error, term()}
  def register(session_id, pid) when is_binary(session_id) and is_pid(pid) do
    Registry.register(@name, session_id, %{pid: pid})
  end

  @doc "Unregisters a session pid."
  @spec unregister(binary(), pid()) :: :ok
  def unregister(session_id, pid) when is_binary(session_id) and is_pid(pid) do
    Registry.unregister(@name, session_id)
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
