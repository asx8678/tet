defmodule Tet.Store do
  @moduledoc """
  Store adapter behaviour owned by the core boundary.

  Concrete store applications implement this behaviour. Runtime code selects an
  adapter through configuration and calls it through this contract instead of
  binding UI code or orchestration code to storage internals.
  """

  @type health :: %{
          required(:application) => atom(),
          required(:adapter) => module(),
          required(:status) => atom(),
          optional(:path) => binary(),
          optional(atom()) => term()
        }

  @callback boundary() :: map()
  @callback health(keyword()) :: {:ok, health()} | {:error, term()}
end
