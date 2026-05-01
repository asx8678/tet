defmodule Tet.Redactor.Inbound do
  @moduledoc """
  Layer 1: Inbound redaction — strips secrets before they reach providers.

  Redacts sensitive values from messages, prompts, and tool results
  before they are sent to LLM providers. This is the first line of
  defense against accidental secret leakage.

  Handles: API keys, tokens, passwords, connection strings, private keys.
  Uses `Tet.Secrets.PatternRegistry` for configurable pattern matching.

  Pure functions, no processes, no side effects.
  """

  alias Tet.Secrets.PatternRegistry

  @redacted "[REDACTED]"

  @type opts :: [patterns: [PatternRegistry.pattern()]]

  @doc """
  Redacts secrets from a message/prompt map before sending to an LLM provider.

  Recursively walks the data structure, redacting any string values that
  match known secret patterns and any map values under sensitive keys.

  ## Examples

      iex> msg = %{role: "user", content: "Use key sk-abcdefghijklmnopqrstuvwx"}
      iex> result = Tet.Redactor.Inbound.redact_for_provider(msg)
      iex> String.contains?(result.content, "sk-abcdefghijklmnopqrstuvwx")
      false
  """
  @spec redact_for_provider(term()) :: term()
  @spec redact_for_provider(term(), opts()) :: term()
  def redact_for_provider(payload, opts \\ []) do
    redact_deep(payload, opts)
  end

  @doc """
  Redacts secrets from tool output before including in LLM context.

  Applies the same deep redaction as `redact_for_provider/2` but is
  semantically distinct for clarity at call sites.

  ## Examples

      iex> result = %{output: "Connected to postgres://user:pass@host/db"}
      iex> redacted = Tet.Redactor.Inbound.redact_tool_result(result)
      iex> String.contains?(redacted.output, "pass@host")
      false
  """
  @spec redact_tool_result(term()) :: term()
  @spec redact_tool_result(term(), opts()) :: term()
  def redact_tool_result(result, opts \\ []) do
    redact_deep(result, opts)
  end

  # --- Deep redaction engine ---

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
      {key, @redacted}
    else
      {key, redact_deep(item, opts)}
    end
  end

  defp redact_string(value, opts) do
    patterns = patterns_from_opts(opts)

    Enum.reduce(patterns, value, fn {_name, regex, _class}, acc ->
      Regex.replace(regex, acc, @redacted)
    end)
  end

  defp patterns_from_opts(opts) do
    case Keyword.get(opts, :patterns) do
      nil -> PatternRegistry.builtin_patterns()
      custom -> custom
    end
  end
end
