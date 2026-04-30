defmodule Tet.ProfileRegistry.Error do
  @moduledoc "Structured profile registry validation error."

  @enforce_keys [:path, :code, :message]
  defstruct [:path, :code, :message, details: %{}]

  @type t :: %__MODULE__{
          path: [String.t() | non_neg_integer()],
          code: atom(),
          message: String.t(),
          details: map()
        }
end
