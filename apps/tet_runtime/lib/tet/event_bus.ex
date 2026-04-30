defmodule Tet.EventBus do
  @moduledoc """
  Minimal runtime-owned event fanout boundary.

  It uses a plain Registry placeholder so the runtime can boot without any UI
  framework or endpoint process.
  """

  @registry Tet.EventBus.Registry

  @doc "Returns true when the runtime event bus Registry is supervised."
  def started? do
    is_pid(Process.whereis(@registry))
  end

  @doc "Subscribe the caller to a runtime topic."
  def subscribe(topic) do
    if started?() do
      Registry.register(@registry, topic, [])
    else
      {:error, :event_bus_not_started}
    end
  end

  @doc "Publish an event term to subscribers of a runtime topic."
  def publish(topic, event) do
    if started?() do
      Registry.dispatch(@registry, topic, fn entries ->
        for {pid, _value} <- entries, do: send(pid, {:tet_event, topic, event})
      end)
    end

    :ok
  end
end
