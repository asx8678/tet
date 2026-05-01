defmodule Tet.Plugin.Loader do
  @moduledoc """
  Plugin manifest validation and capability accessor (pure, no IO).

  BD-0051 defines the loader as the bridge between plugin manifests and the
  runtime plugin supervisor. This module provides pure validation functions
  (no file IO, no `Application.get_env`, no JSON decoding).

  For file-system discovery and parsing, see `Tet.Runtime.Plugin.Loader` in
  the `tet_runtime` app.

  ## Capability validation

  `validate/1` checks that the entrypoint module is loaded and exports all
  declared capability handler functions. This is a structural check:
  we verify the module exists and that known capability callbacks are present.
  """

  alias Tet.Plugin.{Manifest, Capability}

  @known_capabilities Capability.known_capabilities()

  @doc """
  Validates that a plugin's declared capabilities match its implementation.

  Performs:
    1. Manifest-level validation (known capabilities, trust gating)
    2. Module existence check — the entrypoint module must be loaded
    3. Capability callback check — each declared capability must have a
       corresponding function exported by the entrypoint module

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(Manifest.t()) :: :ok | {:error, term()}
  def validate(%Manifest{} = manifest) do
    with :ok <- validate_known_capabilities(manifest.capabilities, manifest.trust_level),
         :ok <- validate_module_loaded(manifest.entrypoint),
         :ok <- validate_capability_implementations(manifest) do
      :ok
    end
  end

  defp validate_known_capabilities(caps, trust) when is_list(caps) do
    unknown = Enum.reject(caps, &(&1 in @known_capabilities))

    cond do
      unknown != [] ->
        {:error, {:unknown_capabilities, unknown}}

      Capability.validate_for_trust(caps, trust) == :ok ->
        :ok

      true ->
        {:error, :invalid_capabilities_for_trust}
    end
  end

  defp validate_known_capabilities(_, _), do: {:error, :invalid_capabilities}

  @doc """
  Returns the list of capabilities a plugin is authorized to use.

  Only returns capabilities that are both declared in the manifest *and*
  permitted by the trust level.
  """
  @spec capabilities(Manifest.t()) :: [Capability.capability()]
  def capabilities(%Manifest{} = manifest) do
    manifest.capabilities
    |> Enum.filter(&Capability.authorized?(manifest, &1))
  end

  defp validate_module_loaded(module) do
    if is_atom(module) and Code.ensure_loaded?(module) do
      :ok
    else
      {:error, {:entrypoint_not_loaded, module}}
    end
  end

  defp validate_capability_implementations(manifest) do
    module = manifest.entrypoint
    callbacks = Capability.capability_callbacks()

    missing =
      Enum.reduce(manifest.capabilities, [], fn cap, acc ->
        callback = Map.get(callbacks, cap)

        if callback && not function_exported?(module, callback, 2) do
          [{cap, callback} | acc]
        else
          acc
        end
      end)

    missing = Enum.reverse(missing)

    if missing == [] do
      :ok
    else
      {:error, {:missing_capability_callbacks, missing}}
    end
  end
end
