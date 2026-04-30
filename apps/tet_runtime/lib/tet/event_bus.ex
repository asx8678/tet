defmodule Tet.EventBus do
  @moduledoc """
  Minimal runtime-owned event fanout boundary.

  It uses a plain Registry placeholder so the runtime can boot without any UI
  framework or endpoint process.
  """

  @registry Tet.EventBus.Registry

  @doc "Subscribe the caller to a runtime topic."
  def subscribe(topic) do
    Registry.register(@registry, topic, [])
  end

  @doc "Publish an event term to subscribers of a runtime topic."
  def publish(topic, event) do
    Registry.dispatch(@registry, topic, fn entries ->
      for {pid, _value} <- entries, do: send(pid, {:tet_event, topic, event})
    end)

    :ok
  end
end
