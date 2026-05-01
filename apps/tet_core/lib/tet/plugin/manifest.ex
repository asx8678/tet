defmodule Tet.Plugin.Manifest do
  @moduledoc """
  Plugin manifest struct with validation, serialization, and trust gating.

  BD-0051 requires every plugin to carry a manifest declaring its name,
  version, description, author, capabilities, trust level, and entrypoint
  module. Validation enforces that declared capabilities fall within the
  trust level's ceiling — a `:sandboxed` plugin cannot declare `:shell`.

  ## Struct fields

    * `name`         — unique plugin identifier (non-empty binary)
    * `version`      — semver string (non-empty binary)
    * `description`  — human-readable summary (binary, optional)
    * `author`       — author name (binary, optional)
    * `capabilities` — list of declared capability atoms
    * `trust_level`  — `:sandboxed` | `:restricted` | `:full`
    * `entrypoint`   — module atom for the plugin's entry point

  ## Examples

      iex> {:ok, m} = Tet.Plugin.Manifest.new(%{
      ...>   name: "my-plugin",
      ...>   version: "1.0.0",
      ...>   capabilities: [:tool_execution, :file_access],
      ...>   trust_level: :restricted,
      ...>   entrypoint: MyPlugin
      ...> })
      iex> m.name
      "my-plugin"
      iex> Tet.Plugin.Manifest.to_map(m).name
      "my-plugin"
  """

  alias Tet.Plugin.Capability

  @trust_levels [:sandboxed, :restricted, :full]

  @enforce_keys [:name, :version, :capabilities, :trust_level, :entrypoint]
  defstruct [:name, :version, :description, :author, :capabilities, :trust_level, :entrypoint]

  @type trust_level :: :sandboxed | :restricted | :full
  @type t :: %__MODULE__{
          name: binary(),
          version: binary(),
          description: binary() | nil,
          author: binary() | nil,
          capabilities: [Capability.capability()],
          trust_level: trust_level(),
          entrypoint: module()
        }

  @doc "Returns the accepted trust levels."
  @spec trust_levels() :: [trust_level()]
  def trust_levels, do: @trust_levels

  @doc """
  Builds a validated manifest from a map of attrs (atom or string keys).

  Validates:
    1. `name` is a non-empty binary
    2. `version` is a non-empty binary
    3. `trust_level` is one of #{inspect(@trust_levels)}
    4. `entrypoint` is an atom (module name)
    5. `capabilities` is a list of known capability atoms
    6. All declared capabilities are within the trust level ceiling

  Returns `{:ok, manifest}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- validate_name(attrs),
         {:ok, version} <- validate_version(attrs),
         {:ok, trust_level} <- validate_trust_level(attrs),
         {:ok, entrypoint} <- validate_entrypoint(attrs),
         {:ok, capabilities} <- validate_capabilities(attrs),
         :ok <- Capability.validate_for_trust(capabilities, trust_level) do
      description = fetch_optional_string(attrs, :description)
      author = fetch_optional_string(attrs, :author)

      {:ok,
       %__MODULE__{
         name: name,
         version: version,
         description: description,
         author: author,
         capabilities: capabilities,
         trust_level: trust_level,
         entrypoint: entrypoint
       }}
    end
  end

  @doc "Builds a manifest or raises `ArgumentError`."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, manifest} -> manifest
      {:error, reason} -> raise ArgumentError, "invalid plugin manifest: #{inspect(reason)}"
    end
  end

  @doc """
  Serializes a manifest to a plain map (string keys for JSON interop).
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = manifest) do
    %{
      "name" => manifest.name,
      "version" => manifest.version,
      "description" => manifest.description,
      "author" => manifest.author,
      "capabilities" => manifest.capabilities,
      "trust_level" => manifest.trust_level,
      "entrypoint" => inspect(manifest.entrypoint)
    }
  end

  @doc """
  Deserializes a plain map (atom or string keys) into a manifest struct.

  Entrypoint can be a module atom or a string like `"MyPlugin"` which will be
  converted via `String.to_atom/1`. Capability and trust_level strings are
  similarly coerced.

  Returns `{:ok, manifest}` or `{:error, reason}`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(data) when is_map(data) do
    attrs = %{
      name: fetch_value(data, :name),
      version: fetch_value(data, :version),
      description: fetch_value(data, :description),
      author: fetch_value(data, :author),
      capabilities: coerce_capabilities(fetch_value(data, :capabilities)),
      trust_level: coerce_trust_level(fetch_value(data, :trust_level)),
      entrypoint: coerce_entrypoint(fetch_value(data, :entrypoint))
    }

    new(attrs)
  end

  # -- Validators --

  defp validate_name(attrs) do
    case fetch_value(attrs, :name) do
      name when is_binary(name) and byte_size(name) > 0 -> {:ok, name}
      _other -> {:error, :invalid_name}
    end
  end

  defp validate_version(attrs) do
    case fetch_value(attrs, :version) do
      version when is_binary(version) and byte_size(version) > 0 -> {:ok, version}
      _other -> {:error, :invalid_version}
    end
  end

  defp validate_trust_level(attrs) do
    case fetch_value(attrs, :trust_level) do
      level when level in @trust_levels -> {:ok, level}
      _other -> {:error, :invalid_trust_level}
    end
  end

  defp validate_entrypoint(attrs) do
    case fetch_value(attrs, :entrypoint) do
      mod when is_atom(mod) -> {:ok, mod}
      _other -> {:error, :invalid_entrypoint}
    end
  end

  defp validate_capabilities(attrs) do
    known = Capability.known_capabilities()

    case fetch_value(attrs, :capabilities) do
      caps when is_list(caps) ->
        invalid = Enum.reject(caps, &(&1 in known))

        if invalid == [] do
          {:ok, caps}
        else
          {:error, {:unknown_capabilities, invalid}}
        end

      _other ->
        {:error, :invalid_capabilities}
    end
  end

  defp fetch_optional_string(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp fetch_value(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp coerce_capabilities(nil), do: []
  defp coerce_capabilities(caps) when is_list(caps), do: Enum.map(caps, &coerce_capability/1)
  defp coerce_capabilities(_), do: nil

  defp coerce_capability(cap) when is_atom(cap), do: cap
  defp coerce_capability(cap) when is_binary(cap), do: String.to_atom(cap)

  defp coerce_trust_level(level) when level in @trust_levels, do: level
  defp coerce_trust_level(level) when is_binary(level), do: String.to_atom(level)
  defp coerce_trust_level(_), do: nil

  defp coerce_entrypoint(mod) when is_atom(mod), do: mod
  defp coerce_entrypoint(mod) when is_binary(mod), do: String.to_atom("Elixir." <> mod)
  defp coerce_entrypoint(_), do: nil
end
