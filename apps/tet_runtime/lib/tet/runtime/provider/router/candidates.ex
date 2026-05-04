defmodule Tet.Runtime.Provider.Router.Candidates do
  @moduledoc false

  @structural_candidate_keys [:adapter, :config_error, :id, :index, :model, :opts, :provider]

  def route_order(candidates, opts \\ [])

  def route_order(candidates, opts) when is_list(opts) do
    with {:ok, normalized} <- normalize(candidates) do
      {:ok, rotate(normalized, start_index(length(normalized), opts))}
    end
  end

  def route_order(_candidates, _opts), do: {:error, {:invalid_router_candidates, :invalid_opts}}

  def start_index(candidate_count, opts \\ [])

  def start_index(candidate_count, opts)
      when is_integer(candidate_count) and candidate_count > 0 do
    case routing_seed(opts) do
      nil -> 0
      {_source, seed} -> seed |> hash_integer() |> rem(candidate_count)
    end
  end

  def start_index(_candidate_count, _opts), do: 0

  def routing_seed(opts) do
    Enum.find_value([:routing_key, :session_id, :request_id], fn key ->
      case Keyword.get(opts, key) do
        value when value in [nil, ""] -> nil
        value when is_binary(value) -> {key, String.trim(value)}
        value -> {key, inspect(value)}
      end
    end)
  end

  def seed_source(nil), do: nil
  def seed_source({source, _seed}), do: source

  def seed_hash(nil), do: nil

  def seed_hash({_source, seed}) do
    :crypto.hash(:sha256, seed)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc false
  def normalize(candidates) when is_list(candidates) do
    candidates
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {candidate, index}, {:ok, acc} ->
      case normalize_candidate(candidate, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize(_candidates), do: {:error, {:invalid_router_candidates, :not_a_list}}

  defp normalize_candidate(candidate, index) when is_list(candidate) do
    with {:ok, candidate} <- list_candidate_to_map(candidate, index) do
      normalize_candidate(candidate, index)
    end
  end

  defp normalize_candidate(%{} = candidate, index) do
    with {:ok, extra_opts} <- extra_candidate_opts(candidate),
         {:ok, declared_opts} <- declared_candidate_opts(candidate, index) do
      opts = Keyword.merge(extra_opts, declared_opts)

      provider =
        normalize_provider(candidate_value(candidate, :provider) || Keyword.get(opts, :provider))

      adapter = candidate_value(candidate, :adapter) || adapter_for(provider)
      model = candidate_value(candidate, :model) || Keyword.get(opts, :model)
      id = candidate_value(candidate, :id) || model || "candidate-#{index}"

      config_error =
        candidate_value(candidate, :config_error) || adapter_config_error(provider, adapter)

      cond do
        not is_nil(adapter) and not is_atom(adapter) ->
          {:error, {:invalid_router_candidate, index, :invalid_adapter}}

        is_nil(adapter) and is_nil(config_error) ->
          {:error, {:invalid_router_candidate, index, :missing_adapter}}

        true ->
          {:ok,
           %{
             index: index,
             id: id,
             provider: provider || provider_from_adapter(adapter),
             adapter: adapter,
             model: model,
             opts: put_provider_identity(opts, provider, model),
             config_error: config_error
           }}
      end
    end
  end

  defp normalize_candidate(_candidate, index),
    do: {:error, {:invalid_router_candidate, index, :not_a_map_or_keyword}}

  defp list_candidate_to_map(candidate, index) do
    if Enum.all?(candidate, &candidate_entry?/1) do
      {:ok, Map.new(candidate)}
    else
      {:error, {:invalid_router_candidate, index, :invalid_candidate_list}}
    end
  end

  defp candidate_entry?({key, _value}) when is_atom(key) or is_binary(key), do: true
  defp candidate_entry?(_entry), do: false

  defp declared_candidate_opts(candidate, index) do
    case candidate_value(candidate, :opts) do
      nil ->
        {:ok, []}

      opts when is_list(opts) ->
        if Keyword.keyword?(opts) do
          {:ok, opts}
        else
          {:error, {:invalid_router_candidate, index, :invalid_opts}}
        end

      _opts ->
        {:error, {:invalid_router_candidate, index, :invalid_opts}}
    end
  end

  defp extra_candidate_opts(candidate) do
    opts =
      candidate
      |> Enum.reject(fn {key, _value} -> structural_key?(key) end)
      |> Enum.reduce_while([], fn
        {key, value}, acc when is_atom(key) -> {:cont, [{key, value} | acc]}
        {_key, _value}, acc -> {:cont, acc}
      end)
      |> Enum.reverse()

    {:ok, opts}
  end

  defp structural_key?(key) when key in @structural_candidate_keys, do: true

  defp structural_key?(key) when is_binary(key) do
    key in Enum.map(@structural_candidate_keys, &Atom.to_string/1)
  end

  defp structural_key?(_key), do: false

  defp candidate_value(candidate, key) do
    Map.get(candidate, key, Map.get(candidate, Atom.to_string(key)))
  end

  defp normalize_provider(nil), do: nil
  defp normalize_provider(provider) when is_atom(provider), do: provider
  defp normalize_provider("mock"), do: :mock
  defp normalize_provider("openai"), do: :openai_compatible
  defp normalize_provider("openai_compatible"), do: :openai_compatible
  defp normalize_provider("anthropic"), do: :anthropic
  defp normalize_provider("router"), do: :router
  defp normalize_provider(provider), do: provider

  defp adapter_for(:mock), do: Tet.Runtime.Provider.Mock
  defp adapter_for(:openai_compatible), do: Tet.Runtime.Provider.OpenAICompatible
  defp adapter_for(:anthropic), do: Tet.Runtime.Provider.Anthropic
  defp adapter_for(_provider), do: nil

  defp adapter_config_error(nil, nil), do: nil
  defp adapter_config_error(provider, nil), do: {:unknown_provider, provider}
  defp adapter_config_error(_provider, _adapter), do: nil

  defp provider_from_adapter(Tet.Runtime.Provider.Mock), do: :mock
  defp provider_from_adapter(Tet.Runtime.Provider.OpenAICompatible), do: :openai_compatible
  defp provider_from_adapter(Tet.Runtime.Provider.Anthropic), do: :anthropic
  defp provider_from_adapter(_adapter), do: nil

  defp put_provider_identity(opts, provider, model) do
    opts
    |> put_new_present(:provider, provider)
    |> put_new_present(:model, model)
  end

  defp put_new_present(opts, _key, nil), do: opts
  defp put_new_present(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp rotate([], _offset), do: []
  defp rotate(candidates, 0), do: candidates

  defp rotate(candidates, offset) do
    {left, right} = Enum.split(candidates, offset)
    right ++ left
  end

  defp hash_integer(seed) do
    :crypto.hash(:sha256, seed)
    |> binary_part(0, 8)
    |> :binary.decode_unsigned()
  end
end
