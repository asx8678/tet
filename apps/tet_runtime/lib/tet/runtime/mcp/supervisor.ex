defmodule Tet.Runtime.Mcp.Supervisor do
  @moduledoc """
  DynamicSupervisor managing MCP server processes.

  BD-0041 provides runtime lifecycle management for MCP servers. Each started
  server is supervised independently — a crashing server doesn't take down the
  whole system.

  ## Gate conditions

  Only servers that are **enabled** and **not errored** are started. This is
  enforced via `Tet.Mcp.Server.startable?/1` which checks:
    1. `enabled == true`
    2. `status != :error` (unknown and stopped are acceptable)

  The supervisor consults the `Tet.Mcp.Registry` for server configurations and
  health status. Lifecycle events are published via `Tet.EventBus`.

  ## Usage

      # Start a server (must be registered in Mcp.Registry first)
      {:ok, pid} = Tet.Runtime.Mcp.Supervisor.start_server("fs")

      # Stop a server by id
      :ok = Tet.Runtime.Mcp.Supervisor.stop_server("fs")

      # Reload a server (stop + start)
      {:ok, pid} = Tet.Runtime.Mcp.Supervisor.reload_server("fs")

      # List running servers
      [%{id: "fs", pid: #PID<0.123.0>}] = Tet.Runtime.Mcp.Supervisor.list_servers()

  Inspired by `Tet.Runtime.Plugin.Supervisor`.
  """

  use DynamicSupervisor

  alias Tet.Mcp.Registry
  alias Tet.Mcp.Server

  @name Tet.Runtime.Mcp.Supervisor

  @doc "Returns the supervisor atom registered in the supervision tree."
  def name, do: @name

  @doc "Starts the MCP Supervisor."
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  @doc """
  Starts an MCP server under the supervisor by id.

  Looks up the server in the Registry, validates it is startable, and starts
  a `Tet.Runtime.Mcp.Worker` for it.

  Returns `{:ok, pid}`, `{:error, :not_found}`, `{:error, :not_startable}`,
  or `{:error, :already_started}`.
  """
  @spec start_server(binary(), keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, term()}
  def start_server(id, opts \\ []) when is_binary(id) do
    registry = Keyword.get(opts, :registry, Registry)

    with {:ok, %Server{} = server} <- Registry.lookup(id, server: registry),
         :ok <- validate_startable(server),
         :ok <- validate_not_running(id) do
      result =
        DynamicSupervisor.start_child(
          @name,
          {Tet.Runtime.Mcp.Worker, {server, [registry: registry]}}
        )

      result
    end
  end

  @doc """
  Stops a running MCP server by id.

  Returns `:ok` if found and stopped, `{:error, :not_found}` otherwise.
  The Worker's terminate callback syncs the final health status to the Registry.
  """
  @spec stop_server(binary(), keyword()) :: :ok | {:error, :not_found}
  def stop_server(id, _opts \\ []) when is_binary(id) do
    case find_server(id) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(@name, pid)
    end
  end

  @doc """
  Reloads an MCP server: stops it (if running) then starts it again.

  Refreshes the server config from the Registry before restarting, so any
  config changes take effect. Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec reload_server(binary(), keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, term()}
  def reload_server(id, opts \\ []) when is_binary(id) do
    registry = Keyword.get(opts, :registry, Registry)

    # Stop if running (ignore :not_found — it may not be running)
    _ = stop_server(id, opts)

    # Reset status to unknown so it becomes startable again
    case Registry.lookup(id, server: registry) do
      {:ok, server} ->
        # If the server was in error state, reset to unknown
        if server.status == :error do
          {:ok, _} = Registry.update_health(id, :unknown, server: registry)
        end

        start_server(id, opts)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Starts all startable servers from the Registry.

  Returns a result for each startable server:
    - `{:ok, pid}` — server was started successfully.
    - `{:error, :already_started}` — server is already running.
    - `{:error, reason}` — start failed for another reason.
  """
  @spec start_all(keyword()) :: [{:ok, pid()} | {:error, term()}]
  def start_all(opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry)

    Registry.list_startable(server: registry)
    |> Enum.map(fn server ->
      if find_server(server.id) do
        {:error, :already_started}
      else
        start_server(server.id, opts)
      end
    end)
  end

  @doc """
  Lists all running MCP servers with their ids and PIDs.
  """
  @spec list_servers() :: [%{id: binary(), pid: pid()}]
  def list_servers do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@name),
        is_pid(pid) do
      case Tet.Runtime.Mcp.Worker.get_server(pid) do
        %Server{id: id} -> %{id: id, pid: pid}
        _nil -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns the status overview: total, enabled, running, errored counts.
  """
  @spec status(keyword()) :: %{
          total: non_neg_integer(),
          enabled: non_neg_integer(),
          running: non_neg_integer(),
          errored: non_neg_integer()
        }
  def status(opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry)
    all = Registry.list_all(server: registry)

    %{
      total: length(all),
      enabled: Enum.count(all, &Server.enabled?/1),
      running: Enum.count(all, &Server.running?/1),
      errored: Enum.count(all, &(&1.status == :error))
    }
  end

  # -- Private --

  defp find_server(id) do
    Enum.find_value(DynamicSupervisor.which_children(@name), nil, fn {_, pid, _, _} ->
      if is_pid(pid) do
        case Tet.Runtime.Mcp.Worker.get_server(pid) do
          %Server{id: ^id} -> pid
          _ -> nil
        end
      end
    end)
  end

  defp validate_startable(%Server{} = server) do
    if Server.startable?(server), do: :ok, else: {:error, :not_startable}
  end

  defp validate_not_running(id) do
    if find_server(id), do: {:error, :already_started}, else: :ok
  end
end
