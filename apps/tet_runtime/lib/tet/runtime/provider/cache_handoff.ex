defmodule Tet.Runtime.Provider.CacheHandoff do
  @moduledoc """
  Pure cache handoff resolution for profile swaps.

  When the Universal Agent Runtime swaps profiles, the runtime must decide what
  happens to the provider-side prompt cache. This module owns the deterministic
  truth table mapping (cache_policy, adapter_capability) → cache_result.

  ## Outcomes

  - `:preserved` — cache hints carry over intact to the new adapter.
  - `:summarized` — adapter lacks native caching; context is summarized into a
    compact text handoff instead of raw cache_control hints.
  - `:reset` — cache is dropped entirely; the new adapter starts cold.

  ## Resolution rules

  | cache_policy       | adapter :full | adapter :summary | adapter :none |
  |--------------------|---------------|-------------------|---------------|
  | `:preserve`        | preserved     | summarized        | reset         |
  | `:drop`            | reset         | reset             | reset         |
  | `{:replace, _map}` | preserved     | summarized        | reset         |

  The `:drop` policy always resets regardless of adapter capability, because the
  user explicitly asked to discard cache. The `{:replace, _}` policy is treated
  like `:preserve` for capability resolution — the replacement map becomes the
  new cache_hints, but the *outcome* is whether the adapter can use them.

  BD-0019 introduces the contract and pure resolution. Actual summary generation
  and adapter-level cache hint injection belong to later runtime work.
  """

  alias Tet.Provider

  @type cache_policy :: :preserve | :drop | {:replace, map()}
  @type cache_result :: :preserved | :summarized | :reset

  @doc "Resolves the cache handoff outcome from policy and adapter capability."
  @spec resolve(cache_policy(), Provider.cache_capability()) :: cache_result()
  def resolve(cache_policy, adapter_capability)

  def resolve(:preserve, :full), do: :preserved
  def resolve(:preserve, :summary), do: :summarized
  def resolve(:preserve, :none), do: :reset

  def resolve(:drop, _adapter_capability), do: :reset

  def resolve({:replace, _cache_hints}, :full), do: :preserved
  def resolve({:replace, _cache_hints}, :summary), do: :summarized
  def resolve({:replace, _cache_hints}, :none), do: :reset

  @doc "Resolves cache handoff outcome from a profile swap request and target adapter."
  @spec resolve_from_swap(map(), module()) :: cache_result()
  def resolve_from_swap(swap_request, target_adapter) when is_map(swap_request) do
    cache_policy = Map.fetch!(swap_request, :cache_policy)
    adapter_capability = Provider.cache_capability(target_adapter)
    resolve(cache_policy, adapter_capability)
  end

  @doc "Returns all valid cache result atoms in stable order."
  @spec results() :: [cache_result()]
  def results, do: [:preserved, :summarized, :reset]

  @doc "Normalizes a cache result from atom or string form."
  @spec normalize_result(term()) :: {:ok, cache_result()} | {:error, term()}
  def normalize_result(result) when result in [:preserved, :summarized, :reset], do: {:ok, result}

  def normalize_result(result) when is_binary(result) do
    case String.trim(result) do
      "preserved" -> {:ok, :preserved}
      "summarized" -> {:ok, :summarized}
      "reset" -> {:ok, :reset}
      _other -> {:error, {:invalid_cache_result, result}}
    end
  end

  def normalize_result(other), do: {:error, {:invalid_cache_result, other}}
end
