defmodule Tet.Store.MemoryContractTest do
  use ExUnit.Case, async: false

  setup do
    # Ensure any stale agent from a previous test is stopped
    Tet.Store.Memory.stop()

    {:ok, _pid} = Tet.Store.Memory.start_link(name: Tet.Store.Memory)
    Tet.Store.Memory.reset()

    {:ok, opts: []}
  end

  use StoreContractCase, adapter: Tet.Store.Memory
end
