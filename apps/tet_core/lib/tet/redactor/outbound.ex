defmodule Tet.Redactor.Outbound do
  @moduledoc """
  Layer 2: Outbound redaction — strips secrets for audit and persistence.

  Redacts sensitive values before writing to audit logs or persistent stores.
  Unlike inbound redaction, outbound redaction preserves fingerprints for
  correlation — allowing you to trace which secret was used without exposing it.

  Pure functions, no processes, no side effects.
  """

  alias Tet.Secrets
  alias Tet.Secrets.PatternRegistry

  @redacted "[REDACTED]"

  @type opts :: [
          patterns: [PatternRegistry.pattern()],
          fingerprint: boolean()
        ]

  @doc """
  Redacts event data before writing to an audit log.

  Preserves structural metadata (keys, types, sizes) while redacting
  actual secret values. When `fingerprint: true` is passed, replaces
  secrets with their fingerprint for correlation.

  ## Examples

      iex> event = %{action: "call", api_key: "sk-abcdefghijklmnopqrstuvwx"}
      iex> result = Tet.Redactor.Outbound.redact_for_audit(event)
      iex> result.api_key == "[REDACTED]"
      true

      iex> event = %{action: "call", payload: "token=sk-abcdefghijklmnopqrstuvwx"}
      iex> result = Tet.Redactor.Outbound.redact_for_audit(event, fingerprint: true)
      iex> String.starts_with?(result.payload, "token=fp:")
      true
  """
  @spec redact_for_audit(term()) :: term()
  @spec redact_for_audit(term(), opts()) :: term()
  def redact_for_audit(data, opts \\ []) do
    redact_deep(data, opts)
  end

  @doc """
  Redacts data before persisting to a store.

  Same behavior as `redact_for_audit/2` — semantically distinct for
  call-site clarity. Strips provider credentials and user secrets while
  preserving structural metadata.

  ## Examples

      iex> record = %{config: %{password: "hunter2"}, name: "prod"}
      iex> result = Tet.Redactor.Outbound.redact_for_store(record)
      iex> result.config.password == "[REDACTED]"
      true
      iex> result.name == "prod"
      true
  """
  @spec redact_for_store(term()) :: term()
  @spec redact_for_store(term(), opts()) :: term()
  def redact_for_store(data, opts \\ []) do
    redact_deep(data, opts)
  end

  @doc """
  Redacts tool output before returning it as a provider-consumed event.

  Semantically distinct from `redact_for_audit/2` for call-site clarity:
  this is the path for tool results flowing back to the LLM provider.
  Strips secrets without fingerprints (provider should never see them).

  ## Examples

      iex> event = %{output: "Connected to postgres://user:pass@host/db"}
      iex> result = Tet.Redactor.Outbound.redact_for_event(event)
      iex> String.contains?(result.output, "pass@host")
      false
  """
  @spec redact_for_event(term()) :: term()
  @spec redact_for_event(term(), opts()) :: term()
  def redact_for_event(data, opts \\ []) do
    redact_deep(data, Keyword.put(opts, :fingerprint, false))
  end

  # --- Deep redaction with fingerprint support ---

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
      {key, redaction_replacement(item, opts)}
    else
      {key, redact_deep(item, opts)}
    end
  end

  defp redact_string(value, opts) do
    patterns = patterns_from_opts(opts)
    use_fingerprint? = Keyword.get(opts, :fingerprint, false)

    Enum.reduce(patterns, value, fn {_name, regex, _class}, acc ->
      Regex.replace(regex, acc, fn match ->
        if use_fingerprint? do
          Secrets.fingerprint(match)
        else
          @redacted
        end
      end)
    end)
  end

  defp redaction_replacement(value, opts) when is_binary(value) do
    if Keyword.get(opts, :fingerprint, false) do
      Secrets.fingerprint(value)
    else
      @redacted
    end
  end

  defp redaction_replacement(_value, _opts), do: @redacted

  defp patterns_from_opts(opts) do
    case Keyword.get(opts, :patterns) do
      nil -> PatternRegistry.builtin_patterns()
      custom -> custom
    end
  end
end
