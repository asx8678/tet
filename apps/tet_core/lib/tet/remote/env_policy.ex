defmodule Tet.Remote.EnvPolicy do
  @moduledoc """
  Environment variable forwarding policy for remote execution — BD-0053.

  Default deny. Nothing escapes the local machine unless you explicitly list it.
  This module decides which environment variables may be forwarded to a remote
  worker and validates that the allowlist is sane.

  ## Why default-deny?

  Environment variables are a dumping ground for secrets, tokens, and
  configuration that should never leave the local machine. A single
  `AWS_SECRET_ACCESS_KEY` or `DATABASE_URL` leaking into a remote process
  is a security incident. We only forward what you *explicitly* ask for.

  ## Allowlist entries

  Entries are plain environment variable names (e.g., `"PATH"`, `"HOME"`).
  No glob patterns, no wildcards — you name what you need, period.
  """

  @default_safe_env ~w[HOME LANG LC_ALL PATH TERM TZ USER]

  @secret_substrings [
    "apikey",
    "api_key",
    "authorization",
    "aws_secret",
    "credential",
    "database_url",
    "db_password",
    "password",
    "private_key",
    "secret",
    "token"
  ]

  @doc """
  Validates an allowlist of environment variable names.

  - Rejects nil, non-lists, and non-string entries.
  - Rejects names containing `=` (injection attempt).
  - Rejects empty strings.
  - Rejects names that look like secret carriers (heuristic).
  - Deduplicates and returns sorted list.
  """
  @spec validate_allowlist(term()) :: {:ok, [binary()]} | {:error, term()}
  def validate_allowlist(nil), do: {:ok, []}

  def validate_allowlist(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, name} <- validate_env_name(entry),
           :ok <- reject_secret_name(name) do
        {:cont, {:ok, [name | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, names |> Enum.uniq() |> Enum.sort()}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_allowlist(_), do: {:error, {:invalid_env_allowlist, :not_a_list}}

  @doc """
  Filters a map of environment variables against an allowlist.

  Only variables whose names appear in the allowlist are included in the
  result. Everything else is silently dropped — default deny.
  """
  @spec filter_env(map(), [binary()]) :: map()
  def filter_env(env_map, allowlist) when is_map(env_map) and is_list(allowlist) do
    allowed_set = MapSet.new(allowlist)

    env_map
    |> Enum.filter(fn {key, _value} -> MapSet.member?(allowed_set, key) end)
    |> Map.new()
  end

  @doc """
  Filters a map of environment variables, but also redacts values that
  look like secrets even if the key is on the allowlist.

  Belt and suspenders. If someone puts `AWS_SECRET_ACCESS_KEY` on the
  allowlist, we still redact the value — the name alone is a red flag.
  """
  @spec filter_and_redact_env(map(), [binary()]) :: map()
  def filter_and_redact_env(env_map, allowlist) when is_map(env_map) and is_list(allowlist) do
    allowed_set = MapSet.new(allowlist)

    env_map
    |> Enum.filter(fn {key, _value} -> MapSet.member?(allowed_set, key) end)
    |> Map.new(fn {key, value} ->
      if secret_key_name?(key) do
        {key, Tet.Redactor.redacted_value()}
      else
        {key, value}
      end
    end)
  end

  @doc "Returns true when an environment variable name looks like a secret carrier."
  @spec secret_key_name?(binary()) :: boolean()
  def secret_key_name?(name) when is_binary(name) do
    compact =
      name
      |> String.replace("-", "_")
      |> String.downcase()

    Enum.any?(@secret_substrings, &String.contains?(compact, &1))
  end

  def secret_key_name?(_), do: false

  @doc """
  Returns a list of commonly safe environment variable names.

  This is **advisory-only** and must NEVER be auto-applied to a profile.
  New profiles always start with an empty allowlist (`[]`). Use this
  list as a *suggestion* when operators ask "what's safe to forward?".
  """
  @spec suggested_safe_vars() :: [binary()]
  def suggested_safe_vars, do: Enum.sort(@default_safe_env)

  # --- Private ---

  defp validate_env_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" ->
        {:error, {:invalid_env_allowlist, {:empty_name, name}}}

      String.contains?(trimmed, "=") ->
        {:error, {:invalid_env_allowlist, {:name_contains_equals, name}}}

      not valid_env_name_chars?(trimmed) ->
        {:error, {:invalid_env_allowlist, {:invalid_chars, name}}}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_env_name(name) when is_atom(name) and name not in [nil, true, false] do
    name |> Atom.to_string() |> validate_env_name()
  end

  defp validate_env_name(_), do: {:error, {:invalid_env_allowlist, :invalid_type}}

  defp reject_secret_name(name) do
    if secret_key_name?(name) do
      {:error, {:secret_name, name}}
    else
      :ok
    end
  end

  # POSIX env var names: [A-Za-z_][A-Za-z0-9_]*
  defp valid_env_name_chars?(name) do
    Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name)
  end
end
