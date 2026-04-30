defmodule Tet.Redactor do
  @moduledoc """
  Central redaction helper for externally visible debug/diagnostic data.

  This module redacts map values based on sensitive-looking key names while
  preserving the surrounding shape for deterministic snapshots. It intentionally
  avoids inspecting raw prompt content; callers decide which values are safe to
  pass in the first place.
  """

  @redacted "[REDACTED]"
  @sensitive_key_substrings [
    "api_key",
    "apikey",
    "authorization",
    "bearer",
    "credential",
    "password",
    "private_key",
    "secret",
    "access_key"
  ]

  @doc "Returns the canonical replacement string for redacted values."
  @spec redacted_value() :: binary()
  def redacted_value, do: @redacted

  @doc "Returns true when a metadata key name should have its value redacted."
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) do
    key = key |> to_string() |> String.downcase()

    key == "token" or String.ends_with?(key, "_token") or
      Enum.any?(@sensitive_key_substrings, &String.contains?(key, &1))
  end

  @doc "Recursively redacts map/list values whose keys look sensitive."
  @spec redact(term()) :: term()
  def redact(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      if sensitive_key?(key) do
        {key, @redacted}
      else
        {key, redact(item)}
      end
    end)
  end

  def redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  def redact(value), do: value
end
