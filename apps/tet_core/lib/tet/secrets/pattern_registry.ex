defmodule Tet.Secrets.PatternRegistry do
  @moduledoc """
  Built-in pattern registry for known secret formats.

  Provides a curated set of regex patterns that match common secret
  formats (API keys, tokens, private keys, etc). Patterns are pure data
  — no processes, no side effects.

  Each pattern is a tuple of `{name, regex, classification}` where:
  - `name` — human-readable identifier (e.g., `:openai_api_key`)
  - `regex` — compiled regex that matches the secret format
  - `classification` — the secret type atom (e.g., `:api_key`)
  """

  @type pattern :: {name :: atom(), regex :: Regex.t(), classification :: atom()}

  @builtin_patterns [
    {:anthropic_api_key, ~r/\bsk-ant-[A-Za-z0-9_-]{6,}/, :api_key},
    {:openai_project_key, ~r/\bsk-proj-[A-Za-z0-9_-]{6,}/, :api_key},
    {:openai_api_key, ~r/\bsk-[A-Za-z0-9_-]{6,}/, :api_key},
    {:aws_access_key, ~r/\b(AKIA[0-9A-Z]{16})\b/, :api_key},
    {:aws_secret_key, ~r/\b[A-Za-z0-9\/+=]{40}\b/, :api_key},
    {:bearer_token, ~r/\bBearer\s+[A-Za-z0-9._~+\/=:-]{10,}/i, :token},
    {:generic_token_assignment,
     ~r/\b(api[_-]?key|authorization|access[_-]?token|refresh[_-]?token|id[_-]?token|session[_-]?token|token|password|secret)\b\s*[:=]\s*["']?[^\["'\s,;}\]]{8,}/i,
     :token},
    {:connection_string, ~r/(mongodb(\+srv)?|postgres(ql)?|mysql|redis|amqp|mssql):\/\/[^\s"']+/i,
     :connection_string},
    {:private_key_block,
     ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----/s,
     :private_key},
    {:private_key_header, ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/, :private_key},
    {:github_token, ~r/\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{36,}/, :token},
    {:slack_token, ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}/, :token},
    {:generic_secret_in_config,
     ~r/(password|passwd|pwd|secret|token|api_key|apikey)\s*[=:]\s*["'][^"']{8,}["']/i,
     :password},
    {:env_secret_assignment,
     ~r/\b[A-Z_]*(?:API_KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)[A-Z_]*\s*=\s*\S+/, :generic_secret},
    {:json_secret_assignment,
     ~r/["'][a-z_]*(?:api_key|token|secret|password|credential)[a-z_]*["']\s*[:=]\s*["'][^"']+["']/i,
     :generic_secret}
  ]

  @doc """
  Returns all built-in patterns.

  ## Examples

      iex> patterns = Tet.Secrets.PatternRegistry.builtin_patterns()
      iex> Enum.all?(patterns, fn {name, regex, class} ->
      ...>   is_atom(name) and is_struct(regex, Regex) and is_atom(class)
      ...> end)
      true
  """
  @spec builtin_patterns() :: [pattern()]
  def builtin_patterns, do: @builtin_patterns

  @doc """
  Returns the names of all built-in patterns.

  ## Examples

      iex> :openai_api_key in Tet.Secrets.PatternRegistry.pattern_names()
      true
  """
  @spec pattern_names() :: [atom()]
  def pattern_names do
    Enum.map(@builtin_patterns, fn {name, _regex, _class} -> name end)
  end

  @doc """
  Merges custom patterns with built-in patterns.

  Custom patterns take precedence over built-in patterns with the same name.

  ## Examples

      iex> custom = [{:my_key, ~r/MY-[A-Z]+/, :api_key}]
      iex> all = Tet.Secrets.PatternRegistry.merge(custom)
      iex> Enum.any?(all, fn {name, _, _} -> name == :my_key end)
      true
  """
  @spec merge(custom :: [pattern()]) :: [pattern()]
  def merge(custom) when is_list(custom) do
    custom_names = MapSet.new(custom, fn {name, _regex, _class} -> name end)

    builtins_without_overrides =
      Enum.reject(@builtin_patterns, fn {name, _regex, _class} ->
        MapSet.member?(custom_names, name)
      end)

    custom ++ builtins_without_overrides
  end

  @doc """
  Finds the first pattern matching the given string.

  Returns `{name, classification}` or `nil`.

  ## Examples

      iex> Tet.Secrets.PatternRegistry.match("my key is sk-abc123def456ghi789jkl012")
      {:openai_api_key, :api_key}

      iex> Tet.Secrets.PatternRegistry.match("just a normal string")
      nil
  """
  @spec match(binary()) :: {atom(), atom()} | nil
  @spec match(binary(), [pattern()]) :: {atom(), atom()} | nil
  def match(value, patterns \\ @builtin_patterns) when is_binary(value) do
    Enum.find_value(patterns, fn {name, regex, classification} ->
      if Regex.match?(regex, value), do: {name, classification}
    end)
  end

  @doc """
  Returns all patterns matching the given string.

  ## Examples

      iex> matches = Tet.Secrets.PatternRegistry.match_all("key=sk-ant-abcdefghijklmnopqrstu")
      iex> length(matches) >= 1
      true
  """
  @spec match_all(binary()) :: [{atom(), atom()}]
  @spec match_all(binary(), [pattern()]) :: [{atom(), atom()}]
  def match_all(value, patterns \\ @builtin_patterns) when is_binary(value) do
    Enum.flat_map(patterns, fn {name, regex, classification} ->
      if Regex.match?(regex, value), do: [{name, classification}], else: []
    end)
  end
end
