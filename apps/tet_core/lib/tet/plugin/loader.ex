defmodule Tet.Plugin.Loader do
  @moduledoc """
  Plugin discovery, loading, and validation.

  BD-0051 defines the loader as the bridge between plugin manifests on disk
  and the runtime plugin supervisor. It scans configured directories for
  `.json` manifest files, validates them, and provides the `capabilities/1`
  accessor for runtime capability checks.

  ## Discovery directories

  Configured via `config :tet_core, plugin_dirs: ["/path/to/plugins"]`.
  Falls back to `~/.tet/plugins` when no directories are configured.

  ## Manifest file format

  Each plugin directory should contain a `manifest.json` with fields matching
  `Tet.Plugin.Manifest`:

      {
        "name": "my-plugin",
        "version": "1.0.0",
        "description": "A demo plugin",
        "author": "Alice",
        "capabilities": ["tool_execution", "file_access"],
        "trust_level": "restricted",
        "entrypoint": "MyPlugin"
      }

  ## Capability validation

  `validate/1` checks that the entrypoint module is loaded and exports all
  declared capability handler functions. Currently, this is a structural
  check: we verify the module exists and that known capability callbacks
  are present. Future BD items may add deeper contract validation.
  """

  alias Tet.Plugin.{Manifest, Capability}

  @default_plugin_dir "~/.tet/plugins"
  @manifest_filename "manifest.json"

  @doc """
  Scans configured directories for plugin manifests.

  Returns a list of `{:ok, Manifest.t()}` or `{:error, reason}` tuples,
  one per discovered manifest file.

  Directories that don't exist are silently skipped.
  """
  @spec discover() :: [{:ok, Manifest.t()} | {:error, term()}]
  def discover do
    plugin_dirs()
    |> Enum.flat_map(&scan_directory/1)
  end

  @doc """
  Loads a specific plugin by name from the configured directories.

  Searches each plugin directory for a subdirectory matching `name` that
  contains a `manifest.json`. Returns `{:ok, manifest}` on the first match
  or `{:error, {:plugin_not_found, name}}`.
  """
  @spec load(binary()) :: {:ok, Manifest.t()} | {:error, term()}
  def load(name) when is_binary(name) do
    plugin_dirs()
    |> Enum.find_value({:error, {:plugin_not_found, name}}, fn dir ->
      manifest_path = Path.join([dir, name, @manifest_filename])

      if File.exists?(manifest_path) do
        parse_manifest_file(manifest_path)
      else
        nil
      end
    end)
  end

  @doc """
  Validates that a plugin's declared capabilities match its implementation.

  Currently performs:
    1. Manifest-level validation (trust gating, known capabilities)
    2. Module existence check — the entrypoint module must be loaded

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(Manifest.t()) :: :ok | {:error, term()}
  def validate(%Manifest{} = manifest) do
    with :ok <- validate_module_loaded(manifest.entrypoint),
         :ok <- validate_capability_implementations(manifest) do
      :ok
    end
  end

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

  # -- Private helpers --

  defp plugin_dirs do
    case Application.get_env(:tet_core, :plugin_dirs) do
      nil -> [expand_default_dir()]
      dirs -> Enum.map(dirs, &expand_path/1)
    end
  end

  defp expand_default_dir do
    expand_path(@default_plugin_dir)
  end

  defp expand_path(path) when is_binary(path) do
    home = System.user_home() || "/tmp"

    path
    |> String.replace("~", home)
    |> Path.expand()
  end

  defp scan_directory(dir) do
    dir
    |> File.ls()
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.map(fn entry ->
          manifest_path = Path.join([dir, entry, @manifest_filename])

          if File.exists?(manifest_path) do
            parse_manifest_file(manifest_path)
          else
            nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp parse_manifest_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> Manifest.from_map(data)
          {:error, reason} -> {:error, {:invalid_json, path, reason}}
        end

      {:error, reason} ->
        {:error, {:read_error, path, reason}}
    end
  end

  defp validate_module_loaded(module) do
    # Code.ensure_loaded?/1 returns true when the module is already loaded
    # or can be loaded. We do NOT call it for `nil` or non-atoms.
    if is_atom(module) and Code.ensure_loaded?(module) do
      :ok
    else
      {:error, {:entrypoint_not_loaded, module}}
    end
  end

  @capability_callbacks %{
    tool_execution: :handle_tool_call,
    file_access: :handle_file_access,
    network: :handle_network_request,
    shell: :handle_shell_command,
    mcp: :handle_mcp_request
  }

  defp validate_capability_implementations(manifest) do
    module = manifest.entrypoint

    missing =
      Enum.reduce(manifest.capabilities, [], fn cap, acc ->
        callback = Map.get(@capability_callbacks, cap)

        if callback && not function_exported?(module, callback, 2) do
          [{cap, callback} | acc]
        else
          acc
        end
      end)

    # Reverse to maintain declaration order
    missing = Enum.reverse(missing)

    if missing == [] do
      :ok
    else
      {:error, {:missing_capability_callbacks, missing}}
    end
  end
end
