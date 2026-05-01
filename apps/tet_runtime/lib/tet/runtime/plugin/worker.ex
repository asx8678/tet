defmodule Tet.Runtime.Plugin.Worker do
  @moduledoc """
  GenServer wrapper for a loaded plugin.

  Each plugin runs inside a Worker that holds its manifest and delegates
  capability-gated calls to the plugin's entrypoint module. The worker is
  the unit of supervision — if a plugin crashes, only its worker restarts.
  """

  use GenServer

  alias Tet.Plugin.{Manifest, Capability}

  @doc "Starts a plugin worker linked to the caller."
  def start_link(%Manifest{} = manifest) do
    GenServer.start_link(__MODULE__, manifest, name: via(manifest.name))
  end

  @doc "Returns the manifest held by a running plugin worker."
  def get_manifest(pid) do
    GenServer.call(pid, :get_manifest)
  catch
    :exit, _ -> nil
  end

  # -- Callbacks --

  @impl true
  def init(%Manifest{} = manifest) do
    {:ok, manifest}
  end

  @impl true
  def handle_call(:get_manifest, _from, manifest) do
    {:reply, manifest, manifest}
  end

  @impl true
  def handle_call({:invoke, capability, args}, _from, manifest) do
    result =
      Capability.gate(manifest, capability, fn ->
        apply(manifest.entrypoint, callback_for(capability), [manifest, args])
      end)

    {:reply, result, manifest}
  end

  # -- Private --

  defp via(name) do
    {:via, Registry, {Tet.Runtime.Plugin.Registry, name}}
  end

  defp callback_for(:tool_execution), do: :handle_tool_call
  defp callback_for(:file_access), do: :handle_file_access
  defp callback_for(:network), do: :handle_network_request
  defp callback_for(:shell), do: :handle_shell_command
  defp callback_for(:mcp), do: :handle_mcp_request
end
