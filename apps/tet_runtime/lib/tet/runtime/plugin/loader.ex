defmodule Tet.Runtime.Plugin.Loader do
  @moduledoc """
  Plugin discovery and file-system loading.

  This is the IO-capable counterpart to `Tet.Plugin.Loader` (in tet_core).
  It handles scanning directories, reading manifest files, and JSON parsing.
  Manifests are validated through `Tet.Plugin.Manifest.from_map/1`.

  ## Discovery directories

  Configured via `config :tet_runtime, plugin_dirs: ["/path/to/plugins"]`.
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
  """

  alias Tet.Plugin.Manifest

  @default_plugin_dir "~/.tet/plugins"
  @manifest_filename "manifest.json"

  @slug_regex ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]*$/

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

  Validates the name is a safe slug (no `/`, `\\`, `..`, or absolute paths)
  before searching. Searches each plugin directory for a subdirectory
  matching `name` that contains a `manifest.json`. Returns `{:ok, manifest}`
  on the first match or `{:error, {:plugin_not_found, name}}`.
  """
  @spec load(binary()) :: {:ok, Manifest.t()} | {:error, term()}
  def load(name) when is_binary(name) do
    with :ok <- validate_name!(name) do
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
  end

  defp validate_name!(name) do
    if Regex.match?(@slug_regex, name),
      do: :ok,
      else: {:error, {:invalid_plugin_name, name}}
  end

  # -- Private helpers --

  defp plugin_dirs do
    case Application.get_env(:tet_runtime, :plugin_dirs) do
      nil -> [expand_default_dir()]
      dirs when is_list(dirs) -> Enum.map(dirs, &expand_path/1)
      _other -> [expand_default_dir()]
    end
  end

  defp expand_default_dir do
    expand_path(@default_plugin_dir)
  end

  defp expand_path(path) when is_binary(path) do
    home = System.user_home() || "/tmp"

    path
    |> replace_leading_tilde(home)
    |> Path.expand()
  end

  defp replace_leading_tilde("~", home), do: home
  defp replace_leading_tilde("~/" <> rest, home), do: home <> "/" <> rest
  defp replace_leading_tilde(path, _home), do: path

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
end
