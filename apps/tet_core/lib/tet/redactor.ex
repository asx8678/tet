defmodule Tet.Redactor do
  @moduledoc """
  Central redaction helper for externally visible debug/diagnostic data.

  This module redacts map values based on sensitive-looking key names while
  preserving the surrounding shape for deterministic snapshots. It intentionally
  avoids inspecting raw prompt content; callers decide which values are safe to
  pass in the first place.

  ## Three-layer architecture (BD-0068)

  This module remains the backward-compatible entry point. For layer-specific
  redaction, use:

    - `Tet.Redactor.Inbound` — redacts before sending to LLM providers
    - `Tet.Redactor.Outbound` — redacts for audit logs and persistence
    - `Tet.Redactor.Display` — redacts for human-visible output (CLI/web/logs)

  The `redact/1` function here provides general-purpose redaction suitable
  for most use cases. The layered modules offer finer-grained control.
  """

  @redacted "[REDACTED]"
  @sensitive_key_compact_substrings [
    "accesskey",
    "apikey",
    "authorization",
    "bearer",
    "credential",
    "password",
    "privatekey",
    "secret"
  ]
  @sensitive_token_compact_keys [
    "accesstoken",
    "idtoken",
    "refreshtoken",
    "sessiontoken"
  ]
  @sensitive_value_patterns [
    ~r/\bBearer\s+[A-Za-z0-9._~+\/=:-]+/i,
    ~r/\b(api[_-]?key|authorization|access[_-]?token|refresh[_-]?token|id[_-]?token|session[_-]?token|token|password|secret)\b\s*[:=]\s*["']?[^\["'\s,;}\]]+/i,
    ~r/\bsk-[A-Za-z0-9_-]{6,}\b/
  ]

  @doc "Returns the canonical replacement string for redacted values."
  @spec redacted_value() :: binary()
  def redacted_value, do: @redacted

  @doc "Returns true when a metadata key name should have its value redacted."
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> sensitive_key_name?()
  end

  def sensitive_key?(key) when is_binary(key), do: sensitive_key_name?(key)
  def sensitive_key?(_key), do: false

  defp sensitive_key_name?(key) do
    fragments = key_fragments(key)
    compact = Enum.join(fragments, "")

    token_key?(fragments, compact) or
      Enum.any?(@sensitive_key_compact_substrings, &String.contains?(compact, &1))
  end

  defp key_fragments(key) do
    key
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  defp token_key?([], _compact), do: false

  defp token_key?(fragments, compact) do
    fragments == ["token"] or List.last(fragments) == "token" or
      compact in @sensitive_token_compact_keys
  end

  @doc "Recursively redacts values whose keys or string contents look sensitive."
  @spec redact(term()) :: term()
  def redact(%module{} = value) do
    value
    |> Map.from_struct()
    |> redact()
    |> then(&struct(module, &1))
  rescue
    _exception -> value
  end

  def redact(value) when is_map(value) do
    Map.new(value, fn {key, item} -> redact_key_value(key, item) end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)

  def redact({key, item}) do
    redact_key_value(key, item)
  end

  def redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(value) when is_binary(value) do
    Enum.reduce(@sensitive_value_patterns, value, fn pattern, redacted ->
      Regex.replace(pattern, redacted, @redacted)
    end)
  end

  def redact(value), do: value

  defp redact_key_value(key, item) do
    if sensitive_key?(key) do
      {key, @redacted}
    else
      {key, redact(item)}
    end
  end
end
