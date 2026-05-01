defmodule Tet.Store.MemoryContractTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _started} = Application.ensure_all_started(:tet_store_memory)
    Tet.Store.Memory.reset()

    {:ok, opts: []}
  end

  use StoreContractCase, adapter: Tet.Store.Memory
end
