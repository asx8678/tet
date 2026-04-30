defmodule Tet.ProfileRegistry do
  @moduledoc """
  Pure profile descriptor registry contract.

  Profiles are data, not runtime processes. A descriptor declares the overlays the
  Universal Agent Runtime can later apply when composing prompts, selecting
  tools/models, constraining tasks, shaping schemas, and handling cache policy.
  Runtime code owns file/env lookup; this module owns normalization and
  validation so CLI, runtime, and future UI adapters inspect the same shape.
  """

  alias Tet.ProfileRegistry.{Error, Validator}

  @overlay_kinds [:prompt, :tool, :model, :task, :schema, :cache]

  @type prompt_layer :: %{
          required(:id) => String.t(),
          required(:content) => String.t(),
          optional(:label) => String.t(),
          optional(:metadata) => map()
        }

  @type prompt_overlay :: %{
          optional(:system) => String.t(),
          required(:layers) => [prompt_layer()],
          required(:metadata) => map()
        }

  @type tool_overlay :: %{
          required(:allow) => [String.t()],
          required(:deny) => [String.t()],
          required(:mode) => String.t(),
          required(:metadata) => map()
        }

  @type model_overlay :: %{
          optional(:default_model) => String.t(),
          required(:fallback_models) => [String.t()],
          optional(:profile_pin) => String.t(),
          required(:settings) => map()
        }

  @type task_overlay :: %{
          required(:categories) => [String.t()],
          required(:modes) => [String.t()],
          optional(:default_mode) => String.t(),
          optional(:priority) => String.t(),
          required(:metadata) => map()
        }

  @type schema_overlay :: %{
          optional(:input) => map(),
          optional(:output) => map(),
          optional(:response) => map(),
          optional(:artifact) => map(),
          optional(:tool_call) => map(),
          required(:metadata) => map()
        }

  @type cache_overlay :: %{
          required(:policy) => String.t(),
          optional(:prompt) => boolean(),
          optional(:tools) => boolean(),
          optional(:ttl_seconds) => pos_integer(),
          required(:metadata) => map()
        }

  @type overlays :: %{
          required(:prompt) => prompt_overlay(),
          required(:tool) => tool_overlay(),
          required(:model) => model_overlay(),
          required(:task) => task_overlay(),
          required(:schema) => schema_overlay(),
          required(:cache) => cache_overlay()
        }

  @type profile :: %{
          required(:id) => String.t(),
          required(:display_name) => String.t(),
          required(:description) => String.t(),
          required(:version) => String.t(),
          required(:tags) => [String.t()],
          required(:overlays) => overlays(),
          required(:metadata) => map()
        }

  @type profile_summary :: %{
          required(:id) => String.t(),
          required(:display_name) => String.t(),
          required(:description) => String.t(),
          required(:version) => String.t(),
          required(:tags) => [String.t()],
          required(:default_model) => String.t() | nil,
          required(:overlay_kinds) => [atom()]
        }

  @type t :: %{
          required(:schema_version) => pos_integer(),
          required(:profiles) => %{String.t() => profile()}
        }

  @doc "Returns the overlay kinds every normalized descriptor exposes."
  @spec overlay_kinds() :: [atom()]
  def overlay_kinds, do: @overlay_kinds

  @doc "Decodes JSON registry data and validates it."
  @spec from_json(binary(), keyword()) :: {:ok, t()} | {:error, [Error.t()]}
  def from_json(json, opts \\ []) when is_binary(json) and is_list(opts) do
    json
    |> decode_json()
    |> case do
      {:ok, raw} ->
        validate(raw, opts)

      {:error, message} ->
        {:error,
         [error([], :invalid_json, "profile registry JSON is invalid", %{detail: message})]}
    end
  end

  @doc "Validates decoded registry data and returns the normalized contract shape."
  @spec validate(term(), keyword()) :: {:ok, t()} | {:error, [Error.t()]}
  def validate(raw, opts \\ []) when is_list(opts), do: Validator.validate(raw, opts)

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

  @doc "Returns all profile entries keyed by profile id."
  @spec profiles(t()) :: %{String.t() => profile()}
  def profiles(%{profiles: profiles}), do: profiles

  @doc "Returns deterministic summaries for every profile."
  @spec list_profiles(t()) :: [profile_summary()]
  def list_profiles(%{profiles: profiles}) do
    profiles
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&summary/1)
  end

  @doc "Fetches a profile descriptor by id."
  @spec profile(t(), String.t() | atom()) :: {:ok, profile()} | :error
  def profile(%{profiles: profiles}, id), do: fetch_by_id(profiles, id)

  @doc "Fetches a profile descriptor by id for inspect-style callers."
  @spec inspect_profile(t(), String.t() | atom()) :: {:ok, profile()} | :error
  def inspect_profile(registry, id), do: profile(registry, id)

  @doc "Fetches all overlays for a profile id."
  @spec overlays(t(), String.t() | atom()) :: {:ok, overlays()} | :error
  def overlays(registry, id) do
    with {:ok, profile} <- profile(registry, id) do
      {:ok, profile.overlays}
    end
  end

  @doc "Fetches one named overlay for a profile id."
  @spec overlay(t(), String.t() | atom(), atom() | String.t()) :: {:ok, map()} | :error
  def overlay(registry, id, kind) do
    with {:ok, overlays} <- overlays(registry, id),
         {:ok, kind} <- normalize_overlay_kind(kind) do
      Map.fetch(overlays, kind)
    else
      _ -> :error
    end
  end

  defp summary(profile) do
    %{
      id: profile.id,
      display_name: profile.display_name,
      description: profile.description,
      version: profile.version,
      tags: profile.tags,
      default_model: Map.get(profile.overlays.model, :default_model),
      overlay_kinds: @overlay_kinds
    }
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

  defp normalize_overlay_kind(kind) when is_atom(kind) and kind in @overlay_kinds, do: {:ok, kind}

  defp normalize_overlay_kind(kind) when is_binary(kind) do
    kind = kind |> String.trim() |> String.downcase() |> String.replace("-", "_")

    cond do
      kind == "tools" -> {:ok, :tool}
      true -> Enum.find_value(@overlay_kinds, :error, &overlay_kind_match?(&1, kind))
    end
  end

  defp normalize_overlay_kind(_kind), do: :error

  defp overlay_kind_match?(known, kind) do
    if Atom.to_string(known) == kind, do: {:ok, known}, else: false
  end

  defp id_from_key(key) when is_binary(key), do: normalize_id(key)
  defp id_from_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_id()
  defp id_from_key(_key), do: {:error, "profile ids must be strings or atoms"}

  defp normalize_id(value) do
    case String.trim(value) do
      "" -> {:error, "profile ids must not be blank"}
      id -> {:ok, id}
    end
  end

  defp path_label([]), do: "profile registry"

  defp path_label(path) do
    Enum.map_join(path, ".", &to_string/1)
  end
end
