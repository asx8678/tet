defmodule Tet.ModelRegistry do
  @moduledoc """
  Pure model registry schema and validation contract.

  The registry is intentionally data-first: callers may pass decoded JSON maps
  or Elixir maps, and this module returns a normalized, provider-neutral shape.
  Runtime code owns file/env lookup; core only validates structure and references.
  """

  alias Tet.ModelRegistry.{Error, Validator}

  @type provider :: %{
          required(:id) => String.t(),
          required(:type) => String.t(),
          required(:display_name) => String.t(),
          required(:config) => map()
        }

  @type context_capability :: %{
          required(:window_tokens) => pos_integer(),
          optional(:max_output_tokens) => pos_integer()
        }

  @type boolean_capability :: %{
          required(:supported) => boolean(),
          optional(:parallel) => boolean(),
          optional(:prompt) => boolean(),
          optional(:read) => boolean(),
          optional(:write) => boolean()
        }

  @type capabilities :: %{
          required(:context) => context_capability(),
          required(:cache) => boolean_capability(),
          required(:tool_calls) => boolean_capability()
        }

  @type model :: %{
          required(:id) => String.t(),
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:display_name) => String.t(),
          required(:capabilities) => capabilities(),
          required(:config) => map()
        }

  @type profile_pin :: %{
          required(:profile) => String.t(),
          required(:default_model) => String.t(),
          required(:fallback_models) => [String.t()]
        }

  @type t :: %{
          required(:schema_version) => pos_integer(),
          required(:providers) => %{String.t() => provider()},
          required(:models) => %{String.t() => model()},
          required(:profile_pins) => %{String.t() => profile_pin()}
        }

  @doc "Decodes JSON registry data and validates it."
  @spec from_json(binary()) :: {:ok, t()} | {:error, [Error.t()]}
  def from_json(json) when is_binary(json) do
    json
    |> decode_json()
    |> case do
      {:ok, raw} ->
        validate(raw)

      {:error, message} ->
        {:error, [error([], :invalid_json, "registry JSON is invalid", %{detail: message})]}
    end
  end

  @doc "Validates decoded registry data and returns the normalized contract shape."
  @spec validate(term()) :: {:ok, t()} | {:error, [Error.t()]}
  def validate(raw), do: Validator.validate(raw)

  @doc "Builds a registry validation error. Runtime loaders reuse this shape."
  @spec error([String.t() | non_neg_integer()], atom(), String.t(), map()) :: Error.t()
  def error(path, code, message, details \\ %{}) when is_list(path) and is_atom(code) do
    %Error{path: path, code: code, message: message, details: details}
  end

  @doc "Formats one validation error for humans while keeping the structured shape intact."
  @spec format_error(Error.t()) :: String.t()
  def format_error(%Error{} = error) do
    "#{path_label(error.path)}: #{error.message}"
  end

  @doc "Returns all provider entries keyed by provider id."
  @spec providers(t()) :: %{String.t() => provider()}
  def providers(%{providers: providers}), do: providers

  @doc "Returns all model entries keyed by registry model id."
  @spec models(t()) :: %{String.t() => model()}
  def models(%{models: models}), do: models

  @doc "Returns all profile pins keyed by profile id."
  @spec profile_pins(t()) :: %{String.t() => profile_pin()}
  def profile_pins(%{profile_pins: profile_pins}), do: profile_pins

  @doc "Fetches a provider by id."
  @spec provider(t(), String.t() | atom()) :: {:ok, provider()} | :error
  def provider(%{providers: providers}, id), do: fetch_by_id(providers, id)

  @doc "Fetches a model by registry model id."
  @spec model(t(), String.t() | atom()) :: {:ok, model()} | :error
  def model(%{models: models}, id), do: fetch_by_id(models, id)

  @doc "Fetches a model's declared capabilities by registry model id."
  @spec capabilities(t(), String.t() | atom()) :: {:ok, capabilities()} | :error
  def capabilities(registry, model_id) do
    with {:ok, model} <- model(registry, model_id) do
      {:ok, model.capabilities}
    end
  end

  @doc "Fetches a profile pin by profile id."
  @spec profile_pin(t(), String.t() | atom()) :: {:ok, profile_pin()} | :error
  def profile_pin(%{profile_pins: profile_pins}, profile), do: fetch_by_id(profile_pins, profile)

  @doc "Returns the default model pinned to a profile."
  @spec pinned_model(t(), String.t() | atom()) :: {:ok, model()} | :error
  def pinned_model(registry, profile) do
    with {:ok, pin} <- profile_pin(registry, profile) do
      model(registry, pin.default_model)
    end
  end

  defp decode_json(json) do
    {:ok, :json.decode(json)}
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason)}
  end

  defp fetch_by_id(entries, id) do
    case id_from_key(id) do
      {:ok, normalized_id} -> Map.fetch(entries, normalized_id)
      {:error, _message} -> :error
    end
  end

  defp id_from_key(key) when is_binary(key), do: normalize_id(key)
  defp id_from_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_id()
  defp id_from_key(_key), do: {:error, "registry ids must be strings or atoms"}

  defp normalize_id(value) do
    case String.trim(value) do
      "" -> {:error, "registry ids must not be blank"}
      id -> {:ok, id}
    end
  end

  defp path_label([]), do: "registry"

  defp path_label(path) do
    Enum.map_join(path, ".", &to_string/1)
  end
end
