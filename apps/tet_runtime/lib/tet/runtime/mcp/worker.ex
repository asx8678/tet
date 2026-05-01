defmodule Tet.Runtime.Mcp.Worker do
  @moduledoc """
  GenServer wrapper for a running MCP server process.

  Each MCP server that the DynamicSupervisor starts gets its own Worker.
  The Worker holds the `Tet.Mcp.Server` struct and is responsible for:
    - Reporting health via heartbeat (synced back to the Registry).
    - Publishing lifecycle events through the EventBus.
    - Updating the Registry when the worker stops or crashes.
    - Being the unit of supervision — a crashing worker only restarts itself.

  ## Registry sync

  Workers receive the Registry identity via child args and sync health
  changes back to it:
    - On init: Registry is updated to `:running`.
    - On heartbeat: `Registry.heartbeat/2` is called.
    - On termination: Registry is updated to `:stopped` (normal) or `:error`
      (abnormal), and the lifecycle event carries the correct final status.

  Inspired by `Tet.Runtime.Plugin.Worker`.
  """

  use GenServer

  alias Tet.Mcp.Registry, as: McpRegistry
  alias Tet.Mcp.Server

  @doc """
  Starts a worker linked to the caller.

  Accepts a `{Server.t(), keyword()}` tuple or a bare `Server.t()` (for
  backward compatibility). The keyword list may include `:registry` to
  specify the Registry GenServer name.
  """
  @spec start_link({Server.t(), keyword()} | Server.t()) :: GenServer.on_start()
  def start_link({%Server{} = server, opts}) do
    GenServer.start_link(__MODULE__, {server, opts}, name: via(server.id))
  end

  def start_link(%Server{} = server) do
    GenServer.start_link(__MODULE__, {server, []}, name: via(server.id))
  end

  @doc "Returns the server struct held by a running worker."
  @spec get_server(pid()) :: Server.t() | nil
  def get_server(pid) do
    GenServer.call(pid, :get_server)
  catch
    :exit, _ -> nil
  end

  @doc "Triggers a heartbeat on a running worker."
  @spec heartbeat(pid()) :: :ok
  def heartbeat(pid) do
    GenServer.cast(pid, :heartbeat)
  end

  # -- Callbacks --

  @impl GenServer
  def init({%Server{} = server, opts}) do
    Process.flag(:trap_exit, true)
    registry = Keyword.get(opts, :registry, McpRegistry)
    server = Server.mark_running(server)
    # Sync running status back to Registry
    _ = McpRegistry.update_health(server.id, :running, server: registry)
    publish_lifecycle_event(server, :started)
    {:ok, %{server: server, registry: registry}}
  end

  @impl GenServer
  def handle_call(:get_server, _from, state) do
    {:reply, state.server, state}
  end

  @impl GenServer
  def handle_cast(
        :heartbeat,
        %{server: %Server{status: :running} = server, registry: registry} = state
      ) do
    updated = Server.heartbeat(server)
    # Sync heartbeat back to Registry
    _ = McpRegistry.heartbeat(server.id, server: registry)
    {:noreply, %{state | server: updated}}
  end

  def handle_cast(:heartbeat, state) do
    {:noreply, state}
  end

  @impl GenServer
  # :DOWN handling is unnecessary here — we trap exits (`Process.flag(:trap_exit, true)`
  # in init/1), so linked-process deaths arrive as {:EXIT, pid, reason} messages instead.
  # This is the OTP-standard equivalent of Process.monitor/`:DOWN` and routes cleanly
  # into terminate/2 for status sync and lifecycle event publishing.
  def handle_info({:EXIT, _from, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, %{server: server, registry: registry} = _state) do
    final_status = if reason == :normal or reason == :shutdown, do: :stopped, else: :error
    final_server = %{server | status: final_status}
    # Sync final status back to Registry
    _ = McpRegistry.update_health(server.id, final_status, server: registry)
    publish_lifecycle_event(final_server, :stopped)
    :ok
  end

  # -- Private --

  defp via(id) do
    {:via, Registry, {Tet.Runtime.Mcp.ProcessRegistry, id}}
  end

  defp publish_lifecycle_event(server, event) do
    if Tet.EventBus.started?() do
      Tet.EventBus.publish("mcp.lifecycle", %{
        server_id: server.id,
        event: event,
        status: server.status,
        timestamp: DateTime.utc_now()
      })
    end

    :ok
  end
end
