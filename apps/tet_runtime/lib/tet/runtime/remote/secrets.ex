defmodule Tet.Runtime.Remote.Secrets do
  @moduledoc false

  @scoped_secret_ref_prefixes ["secret://", "scoped://", "keychain://"]
  @scoped_secret_ref_key_names [
    "auth_secret_ref",
    "auth_secret_refs",
    "scoped_secret_ref",
    "scoped_secret_refs",
    "secret_ref",
    "secret_refs"
  ]
  @transport_raw_secret_key_names [
    "identity",
    "identity_file",
    "key",
    "pem",
    "private_key",
    "privatekey",
    "ssh_key",
    "ssh_private_key"
  ]
  @private_key_value_patterns [
    ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,
    ~r/\bOPENSSH PRIVATE KEY\b/,
    ~r/\b(?:RSA|DSA|EC|ECDSA|ED25519) PRIVATE KEY\b/
  ]
  @private_key_path_pattern ~r/(^|\/)\.ssh\/(id_(?:rsa|dsa|ecdsa|ed25519)|identity)(\b|$)/

  @spec normalize_refs(binary() | [binary()] | nil, keyword()) ::
          {:ok, [binary()]} | {:error, term()}
  def normalize_refs(secret_refs, opts) when is_list(opts) do
    candidates =
      [
        Keyword.get(opts, :auth_secret_ref),
        Keyword.get(opts, :auth_secret_refs),
        Keyword.get(opts, :scoped_secret_ref),
        Keyword.get(opts, :scoped_secret_refs),
        Keyword.get(opts, :secret_ref),
        secret_refs
      ]
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.reject(&is_nil/1)

    candidates
    |> Enum.reduce_while({:ok, []}, fn secret_ref, {:ok, acc} ->
      case normalize_ref(secret_ref) do
        {:ok, secret_ref} -> {:cont, {:ok, [secret_ref | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, refs |> Enum.uniq() |> Enum.sort()}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_ref(term()) :: {:ok, binary()} | {:error, term()}
  def normalize_ref(secret_ref) when is_binary(secret_ref) do
    secret_ref = String.trim(secret_ref)

    cond do
      secret_ref == "" ->
        {:error, {:invalid_scoped_secret_ref, secret_ref}}

      Regex.match?(~r/\s/, secret_ref) ->
        {:error, {:invalid_scoped_secret_ref, :contains_whitespace}}

      scoped_ref?(secret_ref) ->
        {:ok, secret_ref}

      true ->
        {:error, {:invalid_scoped_secret_ref, :unsupported_scheme}}
    end
  end

  def normalize_ref(_secret_ref), do: {:error, {:invalid_scoped_secret_ref, :not_a_string}}

  @spec scoped_ref?(term()) :: boolean()
  def scoped_ref?(value) when is_binary(value) do
    Enum.any?(@scoped_secret_ref_prefixes, &String.starts_with?(value, &1))
  end

  def scoped_ref?(_value), do: false

  @spec assert_no_raw(term()) :: :ok | {:error, {:raw_secret_not_allowed, term()}}
  def assert_no_raw(value) do
    assert_no_raw_with_opts(value, [])
  end

  @spec assert_no_raw_transport(term()) :: :ok | {:error, {:raw_secret_not_allowed, term()}}
  def assert_no_raw_transport(value) do
    assert_no_raw_with_opts(value, transport?: true)
  end

  @spec redact(term()) :: term()
  def redact(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> redact_key_value(key, nested) end)
  end

  def redact(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.map(value, fn {key, nested} -> redact_key_value(key, nested) end)
    else
      Enum.map(value, &redact/1)
    end
  end

  def redact(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact/1)
    |> List.to_tuple()
  end

  def redact(value) when is_binary(value) do
    if private_key_material?(value) do
      Tet.Redactor.redacted_value()
    else
      Tet.Redactor.redact(value)
    end
  end

  def redact(value), do: Tet.Redactor.redact(value)

  defp redact_key_value(key, nested) do
    cond do
      scoped_ref_key?(key) and scoped_ref_value?(nested) ->
        {key, nested}

      safe_secret_summary?(key, nested) ->
        {key, nested}

      Tet.Redactor.sensitive_key?(key) ->
        {key, Tet.Redactor.redacted_value()}

      true ->
        {key, redact(nested)}
    end
  end

  defp assert_no_raw_with_opts(value, opts) do
    case raw_secret_path(value, [], opts) do
      nil -> :ok
      [] -> {:error, {:raw_secret_not_allowed, :top_level}}
      path -> {:error, {:raw_secret_not_allowed, List.last(path)}}
    end
  end

  defp raw_secret_path(value, path, opts) when is_map(value) do
    Enum.find_value(value, fn {key, nested} ->
      raw_secret_path_for_key(key, nested, path, opts)
    end)
  end

  defp raw_secret_path(value, path, opts) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.find_value(value, fn {key, nested} ->
        raw_secret_path_for_key(key, nested, path, opts)
      end)
    else
      value
      |> Enum.with_index()
      |> Enum.find_value(fn {nested, index} -> raw_secret_path(nested, path ++ [index], opts) end)
    end
  end

  defp raw_secret_path(value, path, opts) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> raw_secret_path(path, opts)
  end

  defp raw_secret_path(value, path, _opts) when is_binary(value) do
    cond do
      scoped_ref?(value) -> nil
      private_key_material?(value) -> path
      Tet.Redactor.redact(value) != value -> path
      true -> nil
    end
  end

  defp raw_secret_path(_value, _path, _opts), do: nil

  defp raw_secret_path_for_key(key, nested, path, opts) do
    cond do
      scoped_ref_key?(key) and scoped_ref_value?(nested) ->
        nil

      safe_secret_summary?(key, nested) ->
        nil

      transport_check?(opts) and transport_raw_secret_key?(key) and
          transport_raw_secret_value?(nested) ->
        path ++ [key]

      Tet.Redactor.sensitive_key?(key) ->
        path ++ [key]

      true ->
        raw_secret_path(nested, path ++ [key], opts)
    end
  end

  defp private_key_material?(value) when is_binary(value) do
    trimmed = String.trim(value)

    Enum.any?(@private_key_value_patterns, &Regex.match?(&1, trimmed)) or
      Regex.match?(@private_key_path_pattern, String.downcase(trimmed))
  end

  defp transport_check?(opts), do: Keyword.get(opts, :transport?, false)

  defp transport_raw_secret_key?(key) do
    key
    |> key_name()
    |> String.replace("-", "_")
    |> String.downcase()
    |> then(&(&1 in @transport_raw_secret_key_names))
  end

  defp transport_raw_secret_value?(nil), do: false

  defp transport_raw_secret_value?(value) when is_binary(value) do
    value = String.trim(value)
    value != "" and not scoped_ref?(value)
  end

  defp transport_raw_secret_value?(values) when is_list(values) do
    values != [] and not scoped_ref_value?(values)
  end

  defp transport_raw_secret_value?(_value), do: true

  defp scoped_ref_value?(value) when is_binary(value), do: scoped_ref?(value)

  defp scoped_ref_value?(values) when is_list(values) do
    Enum.all?(values, &scoped_ref_value?/1)
  end

  defp scoped_ref_value?(_value), do: false

  defp safe_secret_summary?(key, value) when is_binary(value) do
    key in [:secret, :secrets, "secret", "secrets"] and
      value in ["none", "redacted", "scoped_refs_only"]
  end

  defp safe_secret_summary?(_key, _value), do: false

  defp scoped_ref_key?(key) do
    key
    |> key_name()
    |> String.replace("-", "_")
    |> String.downcase()
    |> then(&(&1 in @scoped_secret_ref_key_names))
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: inspect(key)
end
