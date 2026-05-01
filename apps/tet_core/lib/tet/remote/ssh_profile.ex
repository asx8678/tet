defmodule Tet.Remote.SSHProfile do
  @moduledoc """
  SSH profile schema for remote worker connections — BD-0053.

  Every remote connection must declare its host identity, authentication
  mechanism, and trust boundary *explicitly*. No ambient credentials, no
  implicit SSH-agent fallback, no "just use the default key" hand-waving.

  ## Host-key pinning

  The `host_key_fingerprint` field is mandatory for `:trusted_remote` profiles
  and above. An empty fingerprint at `:untrusted_remote` trust means the
  connection will be refused — you must pin *something*, even if it's a
  TOFU (trust-on-first-use) fingerprint you just verified by hand.

  ## Secret discipline

  `identity_file` stores a *path*, not key material. Raw private keys must
  never appear in profiles; they belong in the OS keychain or an encrypted
  secret store resolved at runtime by `Tet.Runtime.Remote.Secrets`.
  """

  alias Tet.Redactor
  alias Tet.Remote.EnvPolicy

  @type trust_level :: :local | :trusted_remote | :untrusted_remote

  @enforce_keys [:host, :user, :trust_level]
  defstruct [
    :host,
    :port,
    :user,
    :identity_file,
    :host_key_fingerprint,
    :remote_root,
    :trust_level,
    env_allowlist: []
  ]

  @type t :: %__MODULE__{
          host: binary(),
          port: pos_integer(),
          user: binary(),
          identity_file: binary() | nil,
          host_key_fingerprint: binary() | nil,
          remote_root: binary() | nil,
          trust_level: trust_level(),
          env_allowlist: [binary()]
        }

  @default_ssh_port 22

  # --- Construction ---

  @doc "Builds a validated SSH profile from a keyword list or map."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    normalized = normalize_attrs(attrs)

    with {:ok, host} <- validate_host(fetch_attr(normalized, :host)),
         {:ok, port} <- validate_port(fetch_attr(normalized, :port)),
         {:ok, user} <- validate_user(fetch_attr(normalized, :user)),
         {:ok, identity_file} <- validate_identity_file(fetch_attr(normalized, :identity_file)),
         {:ok, host_key_fingerprint} <-
           validate_host_key_fingerprint(fetch_attr(normalized, :host_key_fingerprint)),
         {:ok, remote_root} <- validate_remote_root(fetch_attr(normalized, :remote_root)),
         {:ok, trust_level} <- validate_trust_level(fetch_attr(normalized, :trust_level)),
         :ok <- validate_fingerprint_for_trust(host_key_fingerprint, trust_level),
         :ok <- validate_identity_file_for_trust(identity_file, trust_level),
         {:ok, env_allowlist} <-
           EnvPolicy.validate_allowlist(fetch_attr(normalized, :env_allowlist)) do
      {:ok,
       %__MODULE__{
         host: host,
         port: port,
         user: user,
         identity_file: identity_file,
         host_key_fingerprint: host_key_fingerprint,
         remote_root: remote_root,
         trust_level: trust_level,
         env_allowlist: env_allowlist
       }}
    end
  end

  @doc """
  Parses an SSH profile from application config.

  Config shape:
      config :tet_core, :ssh_profiles, %{
        "staging" => %{
          host: "staging.example.com",
          port: 2222,
          user: "deploy",
          identity_file: "/home/deploy/.ssh/id_ed25519",
          host_key_fingerprint: "SHA256:abc123...",
          remote_root: "/opt/tet",
          trust_level: :trusted_remote,
          env_allowlist: ["PATH", "HOME"]
        }
      }
  """
  @spec from_config(binary()) :: {:ok, t()} | {:error, term()}
  def from_config(profile_name) when is_binary(profile_name) do
    profiles = Application.get_env(:tet_core, :ssh_profiles, %{})

    case Map.fetch(profiles, profile_name) do
      {:ok, attrs} -> new(attrs)
      :error -> {:error, {:ssh_profile_not_found, profile_name}}
    end
  end

  # --- Host-key pinning ---

  @doc """
  Verifies that a known host fingerprint matches the profile's pinned fingerprint.

  The `known_fingerprint` comes from the SSH handshake (e.g., via
  `ssh-keyscan` or the transport layer). The `pinned_fingerprint` comes
  from the profile. Both are compared after normalization.

  Returns `:ok` on match, `{:error, _}` on mismatch or missing pin.
  """
  @spec verify_host_key(t(), binary()) :: :ok | {:error, term()}
  def verify_host_key(%__MODULE__{host_key_fingerprint: nil}, _known_fingerprint) do
    {:error, :no_pinned_host_key}
  end

  def verify_host_key(%__MODULE__{host_key_fingerprint: pinned}, known_fingerprint)
      when is_binary(pinned) and is_binary(known_fingerprint) do
    pinned_norm = normalize_fingerprint(pinned)
    known_norm = normalize_fingerprint(known_fingerprint)

    if pinned_norm == known_norm do
      :ok
    else
      {:error,
       {:host_key_mismatch,
        %{expected: Redactor.redact(pinned), got: Redactor.redact(known_fingerprint)}}}
    end
  end

  def verify_host_key(%__MODULE__{}, _known_fingerprint) do
    {:error, :invalid_known_fingerprint}
  end

  @doc """
  Normalizes a fingerprint string for comparison.

  For SHA256 fingerprints, only the algorithm prefix is lowercased;
  the base64 hash portion is case-sensitive and preserved.
  For MD5 fingerprints, the entire string is lowercased since hex
  is case-insensitive.
  """
  @spec normalize_fingerprint(binary()) :: binary()
  def normalize_fingerprint(fingerprint) when is_binary(fingerprint) do
    trimmed = fingerprint |> String.trim() |> String.replace(~r/\s+/, "")

    case String.split(trimmed, ":", parts: 2) do
      [algo, hash] when algo in ["SHA256", "sha256"] ->
        "sha256:" <> hash

      _other ->
        String.downcase(trimmed)
    end
  end

  @doc "Returns true when a fingerprint string looks like a valid SHA256 or MD5 host key."
  @spec valid_fingerprint_format?(binary()) :: boolean()
  def valid_fingerprint_format?(fingerprint) when is_binary(fingerprint) do
    trimmed = String.trim(fingerprint)

    sha256_format?(trimmed) or md5_format?(trimmed)
  end

  def valid_fingerprint_format?(_), do: false

  # --- Redaction for logging/telemetry ---

  @doc "Returns a safe map for logging with secrets redacted."
  @spec to_safe_map(t()) :: map()
  def to_safe_map(%__MODULE__{} = profile) do
    %{
      host: profile.host,
      port: profile.port,
      user: profile.user,
      identity_file: Redactor.redacted_value(),
      host_key_fingerprint: Redactor.redacted_value(),
      remote_root: profile.remote_root,
      trust_level: profile.trust_level,
      env_allowlist: profile.env_allowlist
    }
  end

  @doc "Bang version of new/1 — returns the profile or raises."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, profile} -> profile
      {:error, reason} -> raise "invalid SSH profile: #{inspect(reason)}"
    end
  end

  # --- Attr access helpers (atom + string key support) ---

  defp normalize_attrs(attrs) when is_list(attrs), do: attrs
  defp normalize_attrs(attrs) when is_map(attrs), do: attrs

  defp fetch_attr(attrs, key) when is_list(attrs), do: Keyword.get(attrs, key)

  defp fetch_attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  # --- Validation helpers ---

  defp validate_host(nil), do: {:error, {:invalid_ssh_profile, :host_required}}
  defp validate_host(""), do: {:error, {:invalid_ssh_profile, :host_required}}

  @host_allowlist_regex ~r/^[a-zA-Z0-9][a-zA-Z0-9.\-]*$/

  defp validate_host(host) when is_binary(host) do
    trimmed = String.trim(host)

    cond do
      trimmed == "" ->
        {:error, {:invalid_ssh_profile, :host_required}}

      byte_size(trimmed) > 253 ->
        {:error, {:invalid_ssh_profile, {:host_too_long, trimmed}}}

      not Regex.match?(@host_allowlist_regex, trimmed) ->
        {:error, {:invalid_ssh_profile, {:host_invalid_chars, trimmed}}}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_host(host) when is_atom(host) and host not in [nil, true, false] do
    host |> Atom.to_string() |> validate_host()
  end

  defp validate_host(_), do: {:error, {:invalid_ssh_profile, :host_invalid_type}}

  defp validate_port(nil), do: {:ok, @default_ssh_port}
  defp validate_port(port) when is_integer(port) and port > 0 and port <= 65535, do: {:ok, port}

  defp validate_port(port) when is_binary(port) do
    case Integer.parse(String.trim(port)) do
      {n, ""} when n > 0 and n <= 65535 -> {:ok, n}
      _ -> {:error, {:invalid_ssh_profile, {:port_out_of_range, port}}}
    end
  end

  defp validate_port(port), do: {:error, {:invalid_ssh_profile, {:port_out_of_range, port}}}

  defp validate_user(nil), do: {:error, {:invalid_ssh_profile, :user_required}}
  defp validate_user(""), do: {:error, {:invalid_ssh_profile, :user_required}}

  @user_allowlist_regex ~r/^[a-zA-Z_][a-zA-Z0-9_.\-]*\$?$/

  defp validate_user(user) when is_binary(user) do
    trimmed = String.trim(user)

    cond do
      trimmed == "" ->
        {:error, {:invalid_ssh_profile, :user_required}}

      not Regex.match?(@user_allowlist_regex, trimmed) ->
        {:error, {:invalid_ssh_profile, {:user_invalid_chars, trimmed}}}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_user(user) when is_atom(user) and user not in [nil, true, false] do
    user |> Atom.to_string() |> validate_user()
  end

  defp validate_user(_), do: {:error, {:invalid_ssh_profile, :user_invalid_type}}

  defp validate_identity_file(nil), do: {:ok, nil}

  defp validate_identity_file(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> {:ok, nil}
      String.starts_with?(trimmed, "~") -> {:ok, trimmed}
      String.starts_with?(trimmed, "/") -> {:ok, trimmed}
      true -> {:error, {:invalid_ssh_profile, {:identity_file_not_absolute, trimmed}}}
    end
  end

  defp validate_identity_file(_),
    do: {:error, {:invalid_ssh_profile, :identity_file_invalid_type}}

  defp validate_host_key_fingerprint(nil), do: {:ok, nil}

  defp validate_host_key_fingerprint(fingerprint) when is_binary(fingerprint) do
    trimmed = String.trim(fingerprint)

    cond do
      not valid_fingerprint_format?(trimmed) ->
        {:error, {:invalid_ssh_profile, {:host_key_fingerprint_format, fingerprint}}}

      md5_format?(trimmed) ->
        {:error, {:invalid_ssh_profile, {:md5_fingerprint_insecure, fingerprint}}}

      true ->
        {:ok, normalize_fingerprint(trimmed)}
    end
  end

  defp validate_host_key_fingerprint(_),
    do: {:error, {:invalid_ssh_profile, :host_key_fingerprint_invalid_type}}

  defp validate_remote_root(nil), do: {:ok, nil}
  defp validate_remote_root(""), do: {:ok, nil}

  defp validate_remote_root(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        {:ok, nil}

      not String.starts_with?(trimmed, "/") ->
        {:error, {:invalid_ssh_profile, {:remote_root_not_absolute, trimmed}}}

      true ->
        {:ok, trimmed}
    end
  end

  defp validate_remote_root(_), do: {:error, {:invalid_ssh_profile, :remote_root_invalid_type}}

  @trust_levels [:local, :trusted_remote, :untrusted_remote]

  defp validate_trust_level(nil), do: {:error, {:invalid_ssh_profile, :trust_level_required}}

  defp validate_trust_level(level) when level in @trust_levels, do: {:ok, level}

  defp validate_trust_level(level) when is_binary(level) do
    normalized =
      level
      |> String.trim()
      |> String.replace("-", "_")

    case Enum.find(@trust_levels, &(Atom.to_string(&1) == normalized)) do
      nil -> {:error, {:invalid_ssh_profile, {:unknown_trust_level, level}}}
      found -> {:ok, found}
    end
  end

  defp validate_trust_level(level),
    do: {:error, {:invalid_ssh_profile, {:unknown_trust_level, level}}}

  defp validate_fingerprint_for_trust(nil, :local), do: :ok

  defp validate_fingerprint_for_trust(nil, _trust_level),
    do: {:error, {:invalid_ssh_profile, :host_key_fingerprint_required_for_remote}}

  defp validate_fingerprint_for_trust(_fingerprint, _trust_level), do: :ok

  defp validate_identity_file_for_trust(nil, :local), do: :ok

  defp validate_identity_file_for_trust(nil, _trust_level),
    do: {:error, {:invalid_ssh_profile, :identity_file_required_for_remote}}

  defp validate_identity_file_for_trust(_identity_file, _trust_level), do: :ok

  # SHA256: base64-encoded hash, e.g. "SHA256:abc123def456+xyz/w=="
  defp sha256_format?(fingerprint) do
    case String.split(fingerprint, ":", parts: 2) do
      [algo, hash] when algo in ["SHA256", "sha256"] -> sha256_base64?(hash)
      _ -> false
    end
  end

  # Real SHA256 fingerprints decode to 32 bytes → base64 length ~43-44 chars.
  # Reject trivially short hashes like "a" or "abc==".
  @sha256_hash_min_length 40

  defp sha256_base64?(hash) do
    byte_size(hash) >= @sha256_hash_min_length and
      not Regex.match?(~r/[^A-Za-z0-9+\/=]/, hash)
  end

  # MD5: colon-separated hex, e.g. "1a:2b:3c:4d:5e:6f:7a:8b:9c:0d:1e:2f:3a:4b:5c:6d"
  defp md5_format?(fingerprint) do
    parts = String.split(fingerprint, ":")

    length(parts) == 16 and
      Enum.all?(parts, &hex_byte?/1)
  end

  defp hex_byte?(str) do
    Regex.match?(~r/^[0-9a-f]{2}$/i, str)
  end
end
