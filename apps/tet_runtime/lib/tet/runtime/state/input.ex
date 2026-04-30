defmodule Tet.Runtime.State.Input do
  @moduledoc false

  @cache_policies [:preserve, :drop]
  @cache_results [:preserved, :summarized, :reset]
  @cache_capabilities [:full, :summary, :none]

  def fetch_pending_profile_swap(attrs, profile_swap_modes, turn_statuses) do
    case fetch_value(attrs, :pending_profile_swap) do
      nil ->
        {:ok, nil}

      request when is_map(request) ->
        normalize_pending_profile_swap(request, profile_swap_modes, turn_statuses)

      _other ->
        {:error, {:invalid_runtime_state_field, :pending_profile_swap}}
    end
  end

  def pending_profile_swap_to_map(nil), do: nil

  def pending_profile_swap_to_map(request) do
    request
    |> Map.update!(:mode, &Atom.to_string/1)
    |> Map.update!(:blocked_by, &Atom.to_string/1)
    |> Map.update!(:cache_policy, &cache_policy_to_map/1)
    |> put_cache_capability_string()
  end

  defp put_cache_capability_string(request) do
    case Map.fetch(request, :cache_capability) do
      {:ok, cap} -> Map.put(request, :cache_capability, Atom.to_string(cap))
      :error -> Map.put(request, :cache_capability, "none")
    end
  end

  def fetch_profile(attrs, key, aliases \\ []) do
    attrs
    |> fetch_value(key, nil, aliases)
    |> normalize_profile()
  end

  def normalize_profile(nil), do: {:error, {:invalid_runtime_profile, nil}}

  def normalize_profile(profile) when is_boolean(profile),
    do: {:error, {:invalid_runtime_profile, profile}}

  def normalize_profile(profile) when is_atom(profile),
    do: profile |> Atom.to_string() |> normalize_profile()

  def normalize_profile(profile) when is_binary(profile) do
    case String.trim(profile) do
      "" -> {:error, {:invalid_runtime_profile, profile}}
      id -> {:ok, %{id: id, options: %{}}}
    end
  end

  def normalize_profile(profile) when is_map(profile) do
    with {:ok, id} <- fetch_profile_id(profile),
         {:ok, options} <- fetch_map(profile, :options, %{}),
         {:ok, metadata} <- fetch_map(profile, :metadata, %{}),
         {:ok, version} <- fetch_optional_binary(profile, :version) do
      %{id: id, options: options}
      |> put_optional(:metadata, metadata, %{})
      |> put_optional(:version, version, nil)
      |> then(&{:ok, &1})
    end
  end

  def normalize_profile(profile), do: {:error, {:invalid_runtime_profile, profile}}

  def fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_runtime_state_field, key}}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, {:invalid_runtime_state_field, key}}
    end
  end

  def fetch_optional_ref(attrs, key) do
    attrs
    |> fetch_value(key)
    |> normalize_optional_ref(key)
  end

  def fetch_ref_list(attrs, key, default, aliases) do
    case fetch_value(attrs, key, default, aliases) do
      refs when is_list(refs) ->
        refs
        |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
          case normalize_ref(ref, key) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, refs} -> {:ok, Enum.reverse(refs)}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, {:invalid_runtime_state_field, key}}
    end
  end

  def fetch_map(attrs, key, default, aliases \\ []) do
    case fetch_value(attrs, key, default, aliases) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {:invalid_runtime_state_field, key}}
    end
  end

  def fetch_option_map(opts, key, default) when is_list(opts) do
    case Keyword.get(opts, key, default) do
      value when is_map(value) -> {:ok, value}
      _other -> {:error, {:invalid_runtime_state_field, key}}
    end
  end

  def fetch_non_negative_integer(attrs, key, default, aliases \\ []) do
    case fetch_value(attrs, key, default, aliases) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, {:invalid_runtime_state_field, key}}
    end
  end

  def fetch_event_log_cursor(attrs) do
    attrs
    |> fetch_value(:event_log_cursor, nil, [:cursor])
    |> normalize_cursor()
  end

  def fetch_status(attrs, key, default, allowed) do
    attrs
    |> fetch_value(key, default)
    |> normalize_status(allowed, key)
  end

  def normalize_status(status, allowed, key) when is_atom(status) do
    if status in allowed do
      {:ok, status}
    else
      {:error, {:invalid_runtime_state_field, key}}
    end
  end

  def normalize_status(status, allowed, key) when is_binary(status) do
    normalized = String.trim(status)

    Enum.find(allowed, &(Atom.to_string(&1) == normalized))
    |> case do
      nil -> {:error, {:invalid_runtime_state_field, key}}
      status -> {:ok, status}
    end
  end

  def normalize_status(_status, _allowed, key), do: {:error, {:invalid_runtime_state_field, key}}

  def fetch_swap_mode(opts, profile_swap_modes) do
    opts
    |> Keyword.get(:mode, :queue_until_turn_boundary)
    |> normalize_swap_mode(profile_swap_modes)
  end

  def fetch_cache_policy(opts) when is_list(opts) do
    opts
    |> Keyword.get(:cache_policy, :preserve)
    |> normalize_cache_policy()
  end

  def fetch_cache_policy(attrs) when is_map(attrs) do
    attrs
    |> fetch_value(:cache_policy, :preserve)
    |> normalize_cache_policy()
  end

  defp normalize_pending_profile_swap(request, profile_swap_modes, turn_statuses) do
    with {:ok, from_profile} <- fetch_profile(request, :from_profile),
         {:ok, to_profile} <- fetch_profile(request, :to_profile, [:target_profile, :profile]),
         {:ok, mode} <-
           fetch_status(request, :mode, :queue_until_turn_boundary, profile_swap_modes),
         {:ok, sequence} <- fetch_non_negative_integer(request, :requested_at_sequence, 0),
         {:ok, blocked_by} <- fetch_status(request, :blocked_by, :idle, turn_statuses),
         {:ok, cache_policy} <- fetch_cache_policy(request),
         {:ok, cache_capability} <- fetch_cache_capability(request),
         {:ok, metadata} <- fetch_map(request, :metadata, %{}) do
      normalized = %{
        from_profile: from_profile,
        to_profile: to_profile,
        mode: mode,
        requested_at_sequence: sequence,
        blocked_by: blocked_by,
        cache_policy: cache_policy,
        cache_capability: cache_capability
      }

      {:ok, put_optional(normalized, :metadata, metadata, %{})}
    end
  end

  defp fetch_profile_id(profile) do
    case fetch_value(profile, :id, nil, [:name, :profile_id]) do
      id when is_atom(id) and id not in [nil, true, false] ->
        id |> Atom.to_string() |> non_empty_profile_id()

      id when is_binary(id) ->
        non_empty_profile_id(id)

      id ->
        {:error, {:invalid_runtime_profile, id}}
    end
  end

  defp non_empty_profile_id(id) do
    case String.trim(id) do
      "" -> {:error, {:invalid_runtime_profile, id}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_runtime_state_field, key}}
    end
  end

  defp normalize_swap_mode(:queue, _profile_swap_modes), do: {:ok, :queue_until_turn_boundary}
  defp normalize_swap_mode(:reject, _profile_swap_modes), do: {:ok, :reject_mid_turn}

  defp normalize_swap_mode(mode, profile_swap_modes),
    do: normalize_status(mode, profile_swap_modes, :mode)

  defp normalize_cache_policy(policy) when policy in @cache_policies, do: {:ok, policy}

  defp normalize_cache_policy(policy) when is_binary(policy) do
    case String.trim(policy) do
      "preserve" -> {:ok, :preserve}
      "drop" -> {:ok, :drop}
      _other -> {:error, {:invalid_runtime_state_field, :cache_policy}}
    end
  end

  defp normalize_cache_policy({:replace, cache_hints}) when is_map(cache_hints) do
    {:ok, {:replace, cache_hints}}
  end

  defp normalize_cache_policy(policy) when is_map(policy) do
    with replace when replace in [:replace, "replace"] <- fetch_value(policy, :mode, nil, [:kind]),
         {:ok, cache_hints} <- fetch_map(policy, :cache_hints, %{}) do
      {:ok, {:replace, cache_hints}}
    else
      _other -> {:error, {:invalid_runtime_state_field, :cache_policy}}
    end
  end

  defp normalize_cache_policy(_policy),
    do: {:error, {:invalid_runtime_state_field, :cache_policy}}

  defp cache_policy_to_map(:preserve), do: "preserve"
  defp cache_policy_to_map(:drop), do: "drop"

  defp cache_policy_to_map({:replace, cache_hints}),
    do: %{mode: "replace", cache_hints: cache_hints}

  def fetch_cache_capability(opts) when is_list(opts) do
    opts
    |> Keyword.get(:cache_capability, :none)
    |> normalize_cache_capability()
  end

  def fetch_cache_capability(attrs) when is_map(attrs) do
    attrs
    |> fetch_value(:cache_capability, :none)
    |> normalize_cache_capability()
  end

  defp normalize_cache_capability(cap) when cap in @cache_capabilities, do: {:ok, cap}

  defp normalize_cache_capability(cap) when is_binary(cap) do
    case String.trim(cap) do
      "full" -> {:ok, :full}
      "summary" -> {:ok, :summary}
      "none" -> {:ok, :none}
      _other -> {:error, {:invalid_runtime_state_field, :cache_capability}}
    end
  end

  defp normalize_cache_capability(_cap),
    do: {:error, {:invalid_runtime_state_field, :cache_capability}}

  def fetch_cache_result(attrs) do
    case fetch_value(attrs, :cache_result) do
      nil -> {:ok, nil}
      result when result in @cache_results -> {:ok, result}
      result when is_binary(result) -> normalize_cache_result_string(result)
      _other -> {:error, {:invalid_runtime_state_field, :cache_result}}
    end
  end

  defp normalize_cache_result_string(result) do
    case String.trim(result) do
      "preserved" -> {:ok, :preserved}
      "summarized" -> {:ok, :summarized}
      "reset" -> {:ok, :reset}
      _other -> {:error, {:invalid_runtime_state_field, :cache_result}}
    end
  end

  def cache_result_to_string(nil), do: nil
  def cache_result_to_string(result) when is_atom(result), do: Atom.to_string(result)

  defp normalize_optional_ref(nil, _key), do: {:ok, nil}
  defp normalize_optional_ref("", _key), do: {:ok, nil}
  defp normalize_optional_ref(ref, key), do: normalize_ref(ref, key)

  defp normalize_ref(ref, _key) when is_binary(ref) do
    case String.trim(ref) do
      "" -> {:error, {:invalid_runtime_ref, ref}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_ref(ref, _key) when is_map(ref), do: {:ok, ref}
  defp normalize_ref(_ref, key), do: {:error, {:invalid_runtime_state_field, key}}

  defp normalize_cursor(nil), do: {:ok, nil}
  defp normalize_cursor(cursor) when is_integer(cursor) and cursor >= 0, do: {:ok, cursor}
  defp normalize_cursor(cursor), do: normalize_optional_ref(cursor, :event_log_cursor)

  defp fetch_value(attrs, key, default \\ nil, aliases \\ []) do
    keys = [key, Atom.to_string(key) | alias_keys(aliases)]

    Enum.reduce_while(keys, default, fn candidate, _acc ->
      if Map.has_key?(attrs, candidate) do
        {:halt, Map.get(attrs, candidate)}
      else
        {:cont, default}
      end
    end)
  end

  defp alias_keys(aliases) do
    Enum.flat_map(aliases, fn
      alias_key when is_atom(alias_key) -> [alias_key, Atom.to_string(alias_key)]
      alias_key -> [alias_key]
    end)
  end

  defp put_optional(map, _key, value, value), do: map
  defp put_optional(map, key, value, _empty), do: Map.put(map, key, value)
end
