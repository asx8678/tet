defmodule Tet.Runtime.Remote.Transport do
  @moduledoc """
  Behaviour for fakeable remote-worker bootstrap transports.

  Production transport can be SSH-first later. Today the runtime only depends on
  this tiny contract, which keeps tests local and avoids a deeply cursed
  "required VPS in CI" situation.
  """

  alias Tet.Runtime.Remote.Request

  @callback bootstrap(Request.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback install(Request.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback check(Request.t(), keyword()) :: {:ok, map()} | {:error, term()}
end
