defmodule Tet.Provider do
  @moduledoc """
  Provider adapter contract owned by core and implemented by runtime adapters.

  Adapters stream assistant chunks as `%Tet.Event{type: :assistant_chunk}` terms
  through the supplied callback and return the final assistant content.
  """

  @type response :: %{
          required(:content) => binary(),
          optional(:provider) => atom(),
          optional(:model) => binary(),
          optional(:metadata) => map()
        }

  @callback stream_chat([Tet.Message.t()], keyword(), (Tet.Event.t() -> term())) ::
              {:ok, response()} | {:error, term()}
end
