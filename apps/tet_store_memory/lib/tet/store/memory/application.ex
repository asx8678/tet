defmodule Tet.Store.Memory.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{
        id: Tet.Store.Memory,
        start: {Tet.Store.Memory, :start_link, [[name: Tet.Store.Memory]]},
        type: :worker,
        restart: :permanent,
        shutdown: 500
      },
      {Tet.Store.Memory.Registry, []}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Tet.Store.Memory.Supervisor
    )
  end
end
