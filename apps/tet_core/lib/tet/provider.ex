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

  ## Cache capability

  Adapters declare their support for provider-side prompt caching via
  `c:cache_capability/0`. The runtime uses this to determine the cache handoff
  outcome when swapping profiles:

  - `:full`    — adapter supports cache_control hints; cache can be **preserved**.
  - `:summary` — adapter lacks native caching but can accept a text summary;
                 cache is **summarized** into a compact context handoff.
  - `:none`    — adapter supports neither; cache is **reset** (dropped).

  The default implementation returns `:none` so existing adapters opt in
  explicitly rather than silently claiming capabilities they lack.
  """

  @type cache_capability :: :full | :summary | :none

  @type response :: %{
          required(:content) => binary(),
          optional(:provider) => atom(),
          optional(:model) => binary(),
          optional(:metadata) => map()
        }

  @callback stream_chat([Tet.Message.t()], keyword(), (Tet.Event.t() -> term())) ::
              {:ok, response()} | {:error, term()}

  @doc """
  Declares the adapter's support for provider-side prompt caching.

  Returns `:full` when the adapter can preserve cache_control hints across
  requests, `:summary` when it can only accept a text summary of prior context,
  or `:none` when neither is supported. The default is `:none`.
  """
  @callback cache_capability() :: cache_capability()

  @doc "Returns the adapter's cache capability, defaulting to `:none`."
  @spec cache_capability(module()) :: cache_capability()
  def cache_capability(adapter) when is_atom(adapter) do
    case Code.ensure_loaded(adapter) do
      {:module, ^adapter} ->
        if function_exported?(adapter, :cache_capability, 0) do
          adapter.cache_capability()
        else
          :none
        end

      {:error, _reason} ->
        :none
    end
  end
end
