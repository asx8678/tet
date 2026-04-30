defmodule Tet.Provider do
  @moduledoc """
  Provider adapter contract owned by core and implemented by runtime adapters.

  Adapters stream normalized provider lifecycle events through the supplied
  callback and return the final assistant content.

  The normalized event sequence is:

  - `:provider_start` with provider/model/request metadata.
  - `:provider_text_delta` with `%{text: binary()}` for assistant text.
  - `:provider_tool_call_delta` / `:provider_tool_call_done` for tool calls.
  - `:provider_usage` with token counts when the provider supplies them.
  - `:provider_done` with `%{stop_reason: :stop | :length | :tool_use | :error}`.
  - `:provider_error` with `%{kind: atom(), retryable?: boolean(), detail: binary()}`.

  Runtime adapters may also emit legacy `%Tet.Event{type: :assistant_chunk}`
  compatibility events after each `:provider_text_delta`. Those map one-to-one:
  `payload.text` becomes `payload.content`. New consumers should prefer the
  normalized provider events; old CLI/chat callers still get their kibble.
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
