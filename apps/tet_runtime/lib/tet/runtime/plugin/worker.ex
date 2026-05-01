defmodule Tet.Runtime.Plugin.Worker do
  @moduledoc """
  GenServer wrapper for a loaded plugin.

  Each plugin runs inside a Worker that holds its manifest and delegates
  capability-gated calls to the plugin's entrypoint module. The worker is
  the unit of supervision — if a plugin crashes, only its worker restarts.

  ## Error handling

  Unknown capabilities return `{:error, {:unknown_capability, capability}}`.
  Plugin exceptions are caught and returned as `{:error, {:plugin_error, exception}}`.
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
    result = invoke_capability(manifest, capability, args)
    {:reply, result, manifest}
  end

  # Fallback for any other call
  @impl true
  def handle_call(_unknown, _from, manifest) do
    {:reply, {:error, :unknown_request}, manifest}
  end

  # -- Private --

  defp via(name) do
    {:via, Registry, {Tet.Runtime.Plugin.Registry, name}}
  end

  defp invoke_capability(manifest, capability, args) do
    with {:ok, callback} <- lookup_callback(capability) do
      Capability.gate(manifest, capability, fn ->
        try do
          apply(manifest.entrypoint, callback, [manifest, args])
        rescue
          exception ->
            {:error, {:plugin_error, exception}}
        end
      end)
    end
  end

  defp lookup_callback(capability) do
    case Capability.callback_for(capability) do
      nil -> {:error, {:unknown_capability, capability}}
      callback -> {:ok, callback}
    end
  end
end
