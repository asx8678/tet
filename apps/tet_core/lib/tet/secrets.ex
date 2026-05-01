defmodule Tet.Secrets do
  @moduledoc """
  Central secret management boundary.

  Provides classification, detection, and fingerprinting of secret values
  without ever exposing the actual secret content. Pure functions only —
  no processes, no side effects.

  Uses `Tet.Secrets.PatternRegistry` for pattern matching and supports
  registration of custom patterns at call sites.
  """

  alias Tet.Secrets.PatternRegistry

  @type classification ::
          {:secret, :api_key}
          | {:secret, :token}
          | {:secret, :password}
          | {:secret, :private_key}
          | {:secret, :connection_string}
          | :clean

  @type opts :: [patterns: [PatternRegistry.pattern()]]

  @doc """
  Registers a new secret pattern by merging it with built-in patterns.

  Returns the updated pattern list. Since this module is pure (no processes),
  the caller is responsible for threading the patterns through.

  ## Examples

      iex> patterns = Tet.Secrets.register_pattern(:my_key, ~r/MY-[A-Z]{10,}/, :api_key)
      iex> Enum.any?(patterns, fn {name, _, _} -> name == :my_key end)
      true
  """
  @spec register_pattern(atom(), Regex.t(), atom()) :: [PatternRegistry.pattern()]
  def register_pattern(name, regex, classification \\ :token)
      when is_atom(name) and is_struct(regex, Regex) do
    PatternRegistry.merge([{name, regex, classification}])
  end

  @doc """
  Returns all known patterns (built-in).

  ## Examples

      iex> patterns = Tet.Secrets.known_patterns()
      iex> is_list(patterns) and length(patterns) > 0
      true
  """
  @spec known_patterns() :: [PatternRegistry.pattern()]
  def known_patterns, do: PatternRegistry.builtin_patterns()

  @doc """
  Checks if a string contains any known secret pattern.

  ## Examples

      iex> Tet.Secrets.contains_secret?("my key is sk-abcdefghijklmnopqrstuvwx")
      true

      iex> Tet.Secrets.contains_secret?("hello world")
      false
  """
  @spec contains_secret?(binary()) :: boolean()
  @spec contains_secret?(binary(), opts()) :: boolean()
  def contains_secret?(value, opts \\ []) when is_binary(value) do
    patterns = patterns_from_opts(opts)
    PatternRegistry.match(value, patterns) != nil
  end

  @doc """
  Classifies a string value into a secret type.

  Returns `{:secret, type}` if a pattern matches, or `:clean` otherwise.

  ## Examples

      iex> Tet.Secrets.classify("sk-ant-abcdefghijklmnopqrstuvwx")
      {:secret, :api_key}

      iex> Tet.Secrets.classify("Bearer eyJhbGciOiJSUzI1NiJ9.payload.sig")
      {:secret, :token}

      iex> Tet.Secrets.classify("just some text")
      :clean
  """
  @spec classify(binary()) :: classification()
  @spec classify(binary(), opts()) :: classification()
  def classify(value, opts \\ []) when is_binary(value) do
    patterns = patterns_from_opts(opts)

    case PatternRegistry.match(value, patterns) do
      {_name, classification} -> {:secret, classification}
      nil -> :clean
    end
  end

  @doc """
  Returns a safe fingerprint of a secret value for correlation.

  The fingerprint is a truncated SHA-256 hash that allows correlation
  between redacted values without exposing the actual secret.

  Fingerprints are stable — the same input always produces the same output.

  ## Examples

      iex> fp1 = Tet.Secrets.fingerprint("sk-secret123456789012345")
      iex> fp2 = Tet.Secrets.fingerprint("sk-secret123456789012345")
      iex> fp1 == fp2
      true

      iex> fp = Tet.Secrets.fingerprint("some-value")
      iex> String.starts_with?(fp, "fp:")
      true
  """
  @spec fingerprint(binary()) :: binary()
  def fingerprint(value) when is_binary(value) do
    hash =
      :crypto.hash(:sha256, value)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "fp:#{hash}"
  end

  @doc """
  Extracts a safe partial preview for display purposes.

  Shows the prefix and suffix of the value with the middle redacted.
  Useful for "sk-...abc" style displays.

  ## Examples

      iex> Tet.Secrets.partial_preview("sk-abcdefghijklmnopqrstuvwxyz")
      "sk-a...wxyz"

      iex> Tet.Secrets.partial_preview("short")
      "[REDACTED]"
  """
  @spec partial_preview(binary()) :: binary()
  @spec partial_preview(binary(), keyword()) :: binary()
  def partial_preview(value, opts \\ []) when is_binary(value) do
    min_length = Keyword.get(opts, :min_length, 12)
    prefix_len = Keyword.get(opts, :prefix_len, 4)
    suffix_len = Keyword.get(opts, :suffix_len, 4)

    if String.length(value) < min_length do
      "[REDACTED]"
    else
      prefix = String.slice(value, 0, prefix_len)
      suffix = String.slice(value, -suffix_len, suffix_len)
      "#{prefix}...#{suffix}"
    end
  end

  defp patterns_from_opts(opts) do
    case Keyword.get(opts, :patterns) do
      nil -> PatternRegistry.builtin_patterns()
      custom -> custom
    end
  end
end
