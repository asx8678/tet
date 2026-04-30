defmodule Tet.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: Tet.EventBus.Registry}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Tet.Supervisor
    )
  end
end
