defmodule Tet.Event do
  @moduledoc """
  Minimal durable-event shape shared by future runtime and UI adapters.

  Full event schemas arrive in later backlog items. This struct exists now so
  adapters can compile against a stable core-owned event term instead of
  reaching into runtime internals.
  """

  @enforce_keys [:type]
  defstruct [:type, :session_id, :sequence, payload: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          type: atom(),
          session_id: binary() | nil,
          sequence: non_neg_integer() | nil,
          payload: map(),
          metadata: map()
        }
end
