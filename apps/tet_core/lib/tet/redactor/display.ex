defmodule Tet.Redactor.Display do
  @moduledoc """
  Layer 3: Display redaction — redacts for human-visible output.

  Shows partial values (e.g., "sk-...abc") for identification without
  full exposure. Used for CLI output, web UIs, and structured logging.

  Pure functions, no processes, no side effects.
  """

  alias Tet.Secrets
  alias Tet.Secrets.PatternRegistry

  @redacted "[REDACTED]"

  @type opts :: [
          patterns: [PatternRegistry.pattern()],
          partial: boolean()
        ]

  @doc """
  Redacts for CLI/web display with partial value hints.

  When `partial: true` (the default), shows prefix/suffix of secret values
  to aid identification. When `partial: false`, fully redacts.

  ## Examples

      iex> data = %{key: "sk-abcdefghijklmnopqrstuvwx", name: "test"}
      iex> result = Tet.Redactor.Display.redact_for_display(data)
      iex> result.name == "test"
      true
      iex> result.key != "sk-abcdefghijklmnopqrstuvwx"
      true
  """
  @spec redact_for_display(term()) :: term()
  @spec redact_for_display(term(), opts()) :: term()
  def redact_for_display(data, opts \\ []) do
    opts = Keyword.put_new(opts, :partial, true)
    redact_deep(data, opts)
  end

  @doc """
  Redacts for log output — always fully redacts (no partials).

  Logs are often aggregated and searched, so partial values are a risk.
  This uses full redaction unconditionally.

  ## Examples

      iex> msg = "Connecting with sk-abcdefghijklmnopqrstuvwx to api"
      iex> result = Tet.Redactor.Display.redact_for_log(msg)
      iex> String.contains?(result, "sk-abcdefghijklmnopqrstuvwx")
      false
      iex> String.contains?(result, "[REDACTED]")
      true
  """
  @spec redact_for_log(term()) :: term()
  @spec redact_for_log(term(), opts()) :: term()
  def redact_for_log(data, opts \\ []) do
    opts = Keyword.put(opts, :partial, false)
    redact_deep(data, opts)
  end

  # --- Deep redaction with partial display support ---

  defp redact_deep(%module{} = struct, opts) do
    struct
    |> Map.from_struct()
    |> redact_deep(opts)
    |> then(&struct(module, &1))
  rescue
    _exception -> struct
  end

  defp redact_deep(value, opts) when is_map(value) do
    Map.new(value, fn {key, item} -> redact_key_value(key, item, opts) end)
  end

  defp redact_deep(value, opts) when is_list(value) do
    Enum.map(value, &redact_deep(&1, opts))
  end

  defp redact_deep({key, item}, opts) do
    redact_key_value(key, item, opts)
  end

  defp redact_deep(value, opts) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact_deep(&1, opts))
    |> List.to_tuple()
  end

  defp redact_deep(value, opts) when is_binary(value) do
    redact_string(value, opts)
  end

  defp redact_deep(value, _opts), do: value

  defp redact_key_value(key, item, opts) do
    if Tet.Redactor.sensitive_key?(key) do
      {key, display_replacement(item, opts)}
    else
      {key, redact_deep(item, opts)}
    end
  end

  defp redact_string(value, opts) do
    patterns = patterns_from_opts(opts)
    use_partial? = Keyword.get(opts, :partial, true)

    Enum.reduce(patterns, value, fn {_name, regex, _class}, acc ->
      Regex.replace(regex, acc, fn match ->
        if use_partial? do
          Secrets.partial_preview(match)
        else
          @redacted
        end
      end)
    end)
  end

  defp display_replacement(value, opts) when is_binary(value) do
    if Keyword.get(opts, :partial, true) do
      Secrets.partial_preview(value)
    else
      @redacted
    end
  end

  defp display_replacement(_value, _opts), do: @redacted

  defp patterns_from_opts(opts) do
    case Keyword.get(opts, :patterns) do
      nil -> PatternRegistry.builtin_patterns()
      custom -> custom
    end
  end
end
