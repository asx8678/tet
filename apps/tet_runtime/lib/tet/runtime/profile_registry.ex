defmodule Tet.Runtime.ProfileRegistry do
  @moduledoc """
  Runtime loader for editable profile descriptors.

  The loader is intentionally boring IO glue: resolve a path, read JSON, load the
  model registry for cross-reference checks, then delegate schema validation to
  `Tet.ProfileRegistry` in core. No provider calls, no tool execution, no sneaky
  runtime side effects. Good dog.
  """

  @env_path "TET_PROFILE_REGISTRY_PATH"
  @default_priv_path "priv/profile_registry.json"

  @doc "Loads and validates the configured profile registry."
  def load(opts \\ []) when is_list(opts) do
    registry_path = path(opts)

    with {:ok, json} <- read_registry(registry_path),
         {:ok, validation_opts} <- validation_opts(opts) do
      Tet.ProfileRegistry.from_json(json, validation_opts)
    end
  end

  @doc "Returns the registry path chosen by opts, env, app config, or bundled priv data."
  def path(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get(:profile_registry_path)
    |> blank_fallback(System.get_env(@env_path))
    |> blank_fallback(Application.get_env(:tet_runtime, :profile_registry_path))
    |> blank_fallback(default_path())
  end

  @doc "Returns deterministic summaries for all configured profiles."
  def list(opts \\ []) when is_list(opts) do
    with {:ok, registry} <- load(opts) do
      {:ok, Tet.ProfileRegistry.list_profiles(registry)}
    end
  end

  @doc "Fetches one configured profile descriptor."
  def get(profile_id, opts \\ []) when is_list(opts) do
    with {:ok, registry} <- load(opts) do
      case Tet.ProfileRegistry.profile(registry, profile_id) do
        {:ok, profile} -> {:ok, profile}
        :error -> {:error, :profile_not_found}
      end
    end
  end

  @doc "Returns a sanitized diagnostic summary without provider or tool calls."
  def diagnose(opts \\ []) when is_list(opts) do
    registry_path = path(opts)

    case load(opts) do
      {:ok, registry} ->
        {:ok,
         %{
           status: :ok,
           path: registry_path,
           schema_version: registry.schema_version,
           profiles: registry.profiles |> Map.keys() |> Enum.sort(),
           overlay_kinds: Tet.ProfileRegistry.overlay_kinds(),
           message: "profile registry loaded"
         }}

      {:error, errors} ->
        {:error,
         %{
           status: :error,
           path: registry_path,
           errors: errors,
           message: "profile registry invalid: #{format_errors(errors)}"
         }}
    end
  end

  defp validation_opts(opts) do
    if Keyword.get(opts, :validate_model_registry?, true) do
      case Tet.Runtime.ModelRegistry.load(opts) do
        {:ok, model_registry} -> {:ok, [model_registry: model_registry]}
        {:error, errors} -> {:error, errors}
      end
    else
      {:ok, []}
    end
  end

  defp default_path do
    Application.app_dir(:tet_runtime, @default_priv_path)
  end

  defp read_registry(path) do
    case File.read(path) do
      {:ok, json} ->
        {:ok, json}

      {:error, reason} ->
        {:error,
         [
           Tet.ProfileRegistry.error(
             [],
             :registry_unreadable,
             "profile registry could not be read",
             %{
               path: path,
               reason: reason,
               detail: :file.format_error(reason) |> List.to_string()
             }
           )
         ]}
    end
  end

  defp format_errors(errors) do
    errors
    |> Enum.map(&format_error/1)
    |> Enum.join("; ")
  end

  defp format_error(%Tet.ProfileRegistry.Error{} = error),
    do: Tet.ProfileRegistry.format_error(error)

  defp format_error(%Tet.ModelRegistry.Error{} = error), do: Tet.ModelRegistry.format_error(error)
  defp format_error(error), do: inspect(error)

  defp blank_fallback(value, fallback) do
    if blank?(value), do: fallback, else: value
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)
end
