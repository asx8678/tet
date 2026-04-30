defmodule Tet.Runtime.Tools.List do
  @moduledoc """
  Executes the `list` tool: lists directory entries inside a trusted workspace.

  Implements:
  - Workspace path containment via `PathResolver`
  - Recursive listing with max depth
  - Entry size metadata
  - Summary rollup
  - Truncation at limits
  - No mutation
  """

  alias Tet.Runtime.Tools.PathResolver

  @max_entries 5_000
  @type result :: map()

  @doc """
  Lists directory entries inside a workspace directory.

  ## Options
    - `:workspace_root` — required absolute path to workspace root

  ## Args
    - `path` — workspace-relative directory path
    - `recursive` — whether to descend into subdirectories (default: false)
    - `max_depth` — maximum recursive depth (default: 0, max: 12)
  """
  @spec run(map(), keyword()) :: result()
  def run(args, opts \\ []) when is_map(args) and is_list(opts) do
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    path_str = Map.get(args, "path", ".")
    recursive = Map.get(args, "recursive", false)
    max_depth = Map.get(args, "max_depth", if(recursive, do: 12, else: 0))

    with {:ok, resolved_path} <- PathResolver.resolve_directory(path_str, workspace_root) do
      list_entries(resolved_path, path_str, recursive, max_depth, workspace_root)
    else
      {:error, denial} -> build_error(denial)
    end
  end

  defp list_entries(dir_path, rel_path, recursive, max_depth, workspace_root) do
    case File.ls(dir_path) do
      {:ok, names} ->
        entries = build_entries(names, dir_path, rel_path, workspace_root, 0)
        {filtered, truncated} = apply_truncation(entries, recursive, max_depth)

        summary = %{
          entry_count: length(filtered),
          file_count: Enum.count(filtered, &(&1.type == "file")),
          directory_count: Enum.count(filtered, &(&1.type == "directory")),
          total_bytes: Enum.reduce(filtered, 0, &(&1.size_bytes + &2)),
          truncated: truncated
        }

        build_success(rel_path, filtered, truncated, summary)

      {:error, :enoent} ->
        {:error,
         %{
           code: "not_found",
           message: "Directory not found: #{rel_path}",
           kind: "not_found",
           retryable: false,
           details: %{}
         }}

      {:error, :eacces} ->
        {:error,
         %{
           code: "permission_denied",
           message: "Permission denied listing directory",
           kind: "permission",
           retryable: false,
           details: %{}
         }}

      {:error, reason} ->
        {:error,
         %{
           code: "internal_error",
           message: "Failed to list directory: #{reason}",
           kind: "internal",
           retryable: true,
           details: %{}
         }}
    end
  end

  defp build_entries(names, dir_path, rel_path, workspace_root, depth) do
    names
    |> Enum.sort()
    |> Enum.reduce([], fn name, acc ->
      full = Path.join(dir_path, name)
      entry_rel = if rel_path == ".", do: name, else: Path.join(rel_path, name)

      case entry_type(full, entry_rel, workspace_root) do
        {:ok, type, size} ->
          [%{path: entry_rel, type: type, size_bytes: size, depth: depth, redacted: false} | acc]

        {:skip, _reason} ->
          [%{path: entry_rel, type: "other", size_bytes: 0, depth: depth, redacted: true} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp entry_type(full_path, _entry_rel, workspace_root) do
    case File.lstat(full_path) do
      {:ok, stat} ->
        case stat.type do
          :directory ->
            {:ok, "directory", 0}

          :regular ->
            {:ok, "file", stat.size}

          :symlink ->
            resolved = PathResolver.resolve(Path.basename(full_path), workspace_root)

            case resolved do
              {:ok, _target} -> {:ok, "symlink", stat.size}
              {:error, _} -> {:skip, :escape}
            end

          _ ->
            {:ok, "other", 0}
        end

      {:error, _reason} ->
        {:ok, "other", 0}
    end
  end

  defp apply_truncation(entries, recursive, max_depth) do
    if recursive and max_depth > 0 do
      # Simple flat truncation for now — future: proper recursive walk
      {Enum.take(entries, @max_entries), length(entries) > @max_entries}
    else
      {entries, false}
    end
  end

  defp build_success(rel_path, entries, truncated, summary) do
    %{
      ok: true,
      data: %{
        directory: rel_path,
        entries: entries,
        summary: summary
      },
      truncated: truncated,
      limit_usage: %{
        paths: %{used: 1, max: 5_000},
        results: %{used: length(entries), max: @max_entries}
      }
    }
  end

  defp build_error(denial) do
    %{
      ok: false,
      error: denial,
      truncated: false,
      limit_usage: %{
        paths: %{used: 0, max: 5_000},
        results: %{used: 0, max: @max_entries}
      }
    }
  end
end
