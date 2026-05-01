defmodule Tet.Runtime.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for session GenServers.

  Sessions are ephemeral; starting them under a DynamicSupervisor ensures they
  are properly supervised without coupling start/stop to arbitrary callers.
  """

  use DynamicSupervisor

  @name Tet.Runtime.SessionSupervisor

  @doc "Returns the supervisor atom registered in the supervision tree."
  def name, do: @name

  @doc "Starts the SessionSupervisor."
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Starts a new session GenServer under the supervisor."
  @spec start_session(map(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(state_attrs, opts \\ []) do
    DynamicSupervisor.start_child(@name, {Tet.Runtime.Session, {state_attrs, opts}})
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
  end
end
