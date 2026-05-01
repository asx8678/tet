defmodule Tet.Store.SQLite.Repo do
  @moduledoc """
  Ecto repository boundary for the standalone SQLite store.

  This module is intentionally adapter-local. `tet_core`, `tet_runtime`, CLI, and
  optional Phoenix code must not learn about it; they talk to `Tet.Store` domain
  structs and tagged tuples. Phase 2 uses the repo only for the in-app migration
  runner. Phase 3 owns the permanent single-writer process that will decide how
  this repo/connection is supervised.
  """

  use Ecto.Repo,
    otp_app: :tet_store_sqlite,
    adapter: Ecto.Adapters.SQLite3
end
