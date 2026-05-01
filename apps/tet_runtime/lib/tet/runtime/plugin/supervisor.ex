defmodule Tet.Runtime.Plugin.Supervisor do
  @moduledoc """
  DynamicSupervisor managing loaded plugin processes.

  BD-0051 provides runtime lifecycle management for plugins. Each started
  plugin is supervised independently — a crashing plugin doesn't take down
  the whole system.

  Plugins are started as simple GenServers wrapping their entrypoint module.
  The supervisor tracks plugin names to child PIDs for clean shutdown.

  ## Usage

      # Start a plugin (manifest must be validated first)
      {:ok, pid} = Tet.Runtime.Plugin.Supervisor.start_plugin(manifest)

      # Stop a plugin by name
      :ok = Tet.Runtime.Plugin.Supervisor.stop_plugin("my-plugin")

      # List running plugins
      [%{name: "my-plugin", pid: #PID<0.123.0>}] = Tet.Runtime.Plugin.Supervisor.list_plugins()
  """

  use DynamicSupervisor

  @name Tet.Runtime.Plugin.Supervisor

  @doc "Returns the supervisor atom registered in the supervision tree."
  def name, do: @name

  @doc "Starts the PluginSupervisor."
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 5, max_seconds: 60)
  end

  @doc """
  Starts a plugin under the supervisor.

  Expects a validated `Tet.Plugin.Manifest`. The plugin's entrypoint module
  must implement the `Tet.Plugin.Behaviour` callback or be a plain GenServer
  compatible module. We wrap it in a `Tet.Runtime.Plugin.Worker` GenServer
  that holds the manifest and delegates to the entrypoint.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_plugin(Tet.Plugin.Manifest.t()) ::
          DynamicSupervisor.on_start_child() | {:error, :already_started}
  def start_plugin(%Tet.Plugin.Manifest{} = manifest) do
    case find_plugin(manifest.name) do
      nil ->
        DynamicSupervisor.start_child(
          @name,
          {Tet.Runtime.Plugin.Worker, manifest}
        )

      _pid ->
        {:error, :already_started}
    end
  end

  @doc """
  Stops a running plugin by name.

  Returns `:ok` if the plugin was found and stopped, or
  `{:error, :not_found}` if no plugin with that name is running.
  """
  @spec stop_plugin(binary()) :: :ok | {:error, :not_found}
  def stop_plugin(name) when is_binary(name) do
    case find_plugin(name) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(@name, pid)
    end
  end

  @doc """
  Lists all running plugins with their names and PIDs.
  """
  @spec list_plugins() :: [%{name: binary(), pid: pid()}]
  def list_plugins do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@name),
        is_pid(pid) do
      case Tet.Runtime.Plugin.Worker.get_manifest(pid) do
        %Tet.Plugin.Manifest{name: name} -> %{name: name, pid: pid}
        _nil -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  # -- Private --

  defp find_plugin(name) do
    Enum.find_value(DynamicSupervisor.which_children(@name), nil, fn {_, pid, _, _} ->
      if is_pid(pid) do
        case Tet.Runtime.Plugin.Worker.get_manifest(pid) do
          %Tet.Plugin.Manifest{name: ^name} -> pid
          _ -> nil
        end
      end
    end)
  end
end
