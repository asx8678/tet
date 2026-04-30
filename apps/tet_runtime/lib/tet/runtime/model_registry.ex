defmodule Tet.Runtime.ModelRegistry do
  @moduledoc """
  Runtime loader for the editable model registry JSON.

  This module is intentionally boring IO glue: it finds a registry file, reads it,
  and delegates all schema validation to `Tet.ModelRegistry` in core. No network,
  no provider calls, no sneaky router cosplay.
  """

  @env_path "TET_MODEL_REGISTRY_PATH"
  @default_priv_path "priv/model_registry.json"

  @doc "Loads and validates the configured model registry."
  def load(opts \\ []) when is_list(opts) do
    path = path(opts)

    with {:ok, json} <- read_registry(path) do
      Tet.ModelRegistry.from_json(json)
    end
  end

  @doc "Returns the registry path chosen by opts, env, app config, or bundled priv data."
  def path(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get(:model_registry_path)
    |> blank_fallback(System.get_env(@env_path))
    |> blank_fallback(Application.get_env(:tet_runtime, :model_registry_path))
    |> blank_fallback(default_path())
  end

  @doc "Returns a sanitized diagnostic summary without making provider calls."
  def diagnose(opts \\ []) when is_list(opts) do
    registry_path = path(opts)

    case load(opts) do
      {:ok, registry} ->
        {:ok,
         %{
           status: :ok,
           path: registry_path,
           schema_version: registry.schema_version,
           providers: registry.providers |> Map.keys() |> Enum.sort(),
           models: registry.models |> Map.keys() |> Enum.sort(),
           profile_pins: registry.profile_pins |> Map.keys() |> Enum.sort(),
           message: "model registry loaded"
         }}

      {:error, errors} ->
        {:error,
         %{
           status: :error,
           path: registry_path,
           errors: errors,
           message: "model registry invalid: #{format_errors(errors)}"
         }}
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
           Tet.ModelRegistry.error(
             [],
             :registry_unreadable,
             "model registry could not be read",
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
    |> Enum.map(&Tet.ModelRegistry.format_error/1)
    |> Enum.join("; ")
  end

  defp blank_fallback(value, fallback) do
    if blank?(value), do: fallback, else: value
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)
end
