defmodule Tet.Store.Memory.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Tet.Store.Memory, name: Tet.Store.Memory},
      {Tet.Store.Memory.Registry, []}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Tet.Store.Memory.Supervisor
    )
  end
end
