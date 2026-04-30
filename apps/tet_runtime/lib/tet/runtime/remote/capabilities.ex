defmodule Tet.Runtime.Remote.Capabilities do
  @moduledoc """
  Normalizes remote-worker capability declarations.

  Capabilities are claims from a less-trusted worker, so this module keeps them
  deterministic and boring: known keys only, sorted entries, and explicit
  disabled defaults.
  """

  @capability_kinds [:commands, :verifiers, :artifacts, :cancel, :heartbeat]
  @named_capability_kinds [:commands, :verifiers]

  @doc "Returns supported capability kinds in stable order."
  def kinds, do: @capability_kinds

  @doc "Normalizes map or list capability declarations into deterministic data."
  def normalize(capabilities) when is_map(capabilities) do
    Enum.reduce_while(capabilities, {:ok, default_capabilities()}, fn {kind, value}, {:ok, acc} ->
      with {:ok, kind} <- normalize_capability_kind(kind),
           {:ok, capability} <- normalize_capability_value(kind, value) do
        {:cont, {:ok, Map.put(acc, kind, capability)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize(capabilities) when is_list(capabilities) do
    Enum.reduce_while(capabilities, {:ok, default_capabilities()}, fn capability, {:ok, acc} ->
      with {:ok, kind, value} <- list_capability(capability),
           {:ok, normalized} <- normalize_capability_value(kind, value) do
        {:cont, {:ok, Map.put(acc, kind, normalized)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize(_capabilities), do: {:error, {:invalid_remote_capabilities, :not_a_map_or_list}}

  @doc "Requires one normalized capability to be enabled."
  def require_enabled(capabilities, kind) do
    if get_in(capabilities, [kind, :enabled]) == true do
      :ok
    else
      {:error, {:missing_remote_capability, kind}}
    end
  end

  defp list_capability({kind, value}) do
    with {:ok, kind} <- normalize_capability_kind(kind) do
      {:ok, kind, value}
    end
  end

  defp list_capability(kind) do
    with {:ok, kind} <- normalize_capability_kind(kind) do
      {:ok, kind, true}
    end
  end

  defp normalize_capability_value(kind, value) when value in [nil, false] do
    {:ok, disabled_capability(kind)}
  end

  defp normalize_capability_value(kind, true), do: {:ok, enabled_capability(kind, [])}

  defp normalize_capability_value(kind, value)
       when is_list(value) and kind in @named_capability_kinds do
    with {:ok, entries} <- normalize_entries(value, kind) do
      {:ok, enabled_capability(kind, entries)}
    end
  end

  defp normalize_capability_value(kind, value) when is_binary(value) or is_atom(value) do
    cond do
      value in ["true", true] ->
        {:ok, enabled_capability(kind, [])}

      value in ["false", false] ->
        {:ok, disabled_capability(kind)}

      kind in @named_capability_kinds ->
        with {:ok, entry} <- normalize_non_empty(value, kind) do
          {:ok, enabled_capability(kind, [entry])}
        end

      true ->
        {:error, {:invalid_remote_capability, kind}}
    end
  end

  defp normalize_capability_value(kind, value) when is_map(value) do
    enabled = fetch_value(value, :enabled, true, [:enabled?])
    entries = fetch_value(value, :entries, [], [:names, kind])

    with {:ok, enabled} <- normalize_boolean(enabled, kind),
         {:ok, entries} <- normalize_entries(entries, kind) do
      capability =
        if enabled, do: enabled_capability(kind, entries), else: disabled_capability(kind)

      {:ok, capability}
    end
  end

  defp normalize_capability_value(kind, _value), do: {:error, {:invalid_remote_capability, kind}}

  defp normalize_entries(entries, kind)
       when kind in @named_capability_kinds and is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize_non_empty(entry, kind) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, entries |> Enum.uniq() |> Enum.sort()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_entries([], _kind), do: {:ok, []}
  defp normalize_entries(_entries, kind), do: {:error, {:invalid_remote_capability_entries, kind}}

  defp enabled_capability(kind, entries) when kind in @named_capability_kinds do
    %{enabled: true, entries: entries |> Enum.uniq() |> Enum.sort()}
  end

  defp enabled_capability(_kind, _entries), do: %{enabled: true}

  defp disabled_capability(kind) when kind in @named_capability_kinds do
    %{enabled: false, entries: []}
  end

  defp disabled_capability(_kind), do: %{enabled: false}

  defp default_capabilities do
    Map.new(@capability_kinds, &{&1, disabled_capability(&1)})
  end

  defp normalize_capability_kind(kind) when kind in @capability_kinds, do: {:ok, kind}

  defp normalize_capability_kind(kind) when is_binary(kind) do
    normalized = kind |> String.trim() |> String.replace("-", "_")

    Enum.find(@capability_kinds, &(Atom.to_string(&1) == normalized))
    |> case do
      nil -> {:error, {:unknown_remote_capability, kind}}
      kind -> {:ok, kind}
    end
  end

  defp normalize_capability_kind(kind), do: {:error, {:unknown_remote_capability, kind}}

  defp normalize_boolean(value, _field) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean("true", _field), do: {:ok, true}
  defp normalize_boolean("false", _field), do: {:ok, false}
  defp normalize_boolean(_value, field), do: {:error, {:invalid_remote_capability, field}}

  defp normalize_non_empty(value, field)
       when is_atom(value) and value not in [nil, true, false] do
    value |> Atom.to_string() |> normalize_non_empty(field)
  end

  defp normalize_non_empty(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_remote_capability_entry, field}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_non_empty(_value, field), do: {:error, {:invalid_remote_capability_entry, field}}

  defp fetch_value(attrs, key, default, aliases) when is_map(attrs) do
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
end
