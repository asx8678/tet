defmodule Tet.Migration.ConfigMapper do
  @moduledoc """
  Maps legacy CLI config keys to their Tet equivalents — BD-0072.

  Some keys are safe to auto-migrate (simple renames or value transforms),
  others require manual review because they carry security implications or
  reference concepts that don't map one-to-one.
  """

  @compatible %{
    "api_key" => {:provider, "api_key"},
    "model" => {:provider, "model"},
    "base_url" => {:provider, "base_url"},
    "data_dir" => {:store, "path"},
    "timeout" => {:provider, "timeout"},
    "max_tokens" => {:provider, "max_tokens"},
    "temperature" => {:provider, "temperature"},
    "session_path" => {:session, "path"},
    "verbose" => {:logging, "verbose"},
    "auto_save" => {:autosave, "enabled"},
    "auto_save_interval" => {:autosave, "interval_seconds"}
  }

  @unsafe ~w(
    system_prompt
    allowed_tools
    shell_whitelist
    custom_headers
    command_whitelist
    auto_approve_patterns
  )

  @doc """
  Returns a list of legacy key names that can be safely auto-migrated.
  """
  @spec compatible_keys() :: [binary()]
  def compatible_keys, do: Map.keys(@compatible)

  @doc """
  Returns the `{section, new_key}` mapping for a compatible legacy key.

  Returns `nil` if the key is not in the compatible set.
  """
  @spec compatible_mapping(binary()) :: {atom(), binary()} | nil
  def compatible_mapping(key) when is_binary(key) do
    case Map.get(@compatible, key) do
      nil -> nil
      {section, new_key} -> {section, new_key}
    end
  end

  @doc """
  Returns a list of legacy key names that require manual review before migration.
  """
  @spec unsafe_keys() :: [binary()]
  def unsafe_keys, do: @unsafe

  @doc """
  Maps a legacy config map to the new Tet config structure.

  Only compatible keys are mapped. Unsafe keys are collected separately
  for manual review. Unknown keys (neither compatible nor unsafe) are
  collected in the third element of the return tuple.

  Returns `{:ok, mapped, unsafe_found, unknown_found}` where:
  - `mapped` is the new config map
  - `unsafe_found` is a list of unsafe keys present in the legacy config
  - `unknown_found` is a list of unknown keys present in the legacy config
  """
  @spec map_config(map()) :: {:ok, map(), [binary()], [binary()]}
  def map_config(legacy_config) when is_map(legacy_config) do
    {mapped, unsafe_found, unknown_found} =
      legacy_config
      |> Enum.reduce({%{}, [], []}, fn {key, value}, {acc, unsafe_acc, unknown_acc} ->
        key_str = stringify(key)

        cond do
          Map.has_key?(@compatible, key_str) ->
            {section, new_key} = @compatible[key_str]
            transformed = transform_value(key_str, value)
            new_map = put_in_section(acc, section, new_key, transformed)
            {new_map, unsafe_acc, unknown_acc}

          key_str in @unsafe ->
            {acc, [key_str | unsafe_acc], unknown_acc}

          true ->
            {acc, unsafe_acc, [key_str | unknown_acc]}
        end
      end)

    {:ok, mapped, Enum.reverse(unsafe_found), Enum.reverse(unknown_found)}
  end

  @doc """
  Transforms a single legacy value to the new format for the given key.

  Returns the transformed value. Falls back to the original value if no
  special transform is needed. Numeric parsing is strict — trailing
  content after the number is rejected (e.g., "30 seconds" → "30 seconds",
  not 30).
  """
  @spec transform_value(binary(), term()) :: term()
  def transform_value("verbose", value) when is_boolean(value), do: value
  def transform_value("verbose", value) when is_binary(value), do: value in ~w(true yes 1)

  def transform_value("auto_save", value) when is_boolean(value), do: value
  def transform_value("auto_save", value) when is_binary(value), do: value in ~w(true yes 1)

  def transform_value("auto_save_interval", value) when is_binary(value) do
    parse_strict_int(value)
  end

  def transform_value("timeout", value) when is_binary(value) do
    parse_strict_int(value)
  end

  def transform_value("max_tokens", value) when is_binary(value) do
    parse_strict_int(value)
  end

  def transform_value("temperature", value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} when float >= 0.0 and float <= 2.0 -> float
      _ -> value
    end
  end

  def transform_value(_key, value), do: value

  # ── Private helpers ──────────────────────────────────────────────────────

  defp parse_strict_int(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> value
    end
  end

  defp put_in_section(config, section, key, value) do
    section_str = Atom.to_string(section)
    existing = Map.get(config, section_str, %{})
    Map.put(config, section_str, Map.put(existing, key, value))
  end

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: "#{value}"
end
