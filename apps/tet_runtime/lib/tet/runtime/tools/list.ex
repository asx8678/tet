defmodule Tet.Runtime.Tools.List do
  @moduledoc """
  Executes the `list` tool: lists directory entries inside a trusted workspace.

  Implements:
  - Workspace path containment via `PathResolver`
  - Realpath defense-in-depth check before I/O
  - Recursive listing with max depth
  - Entry size metadata
  - Summary rollup with truncation propagation
  - Truncation at limits enforced at the I/O boundary
  - Non-recursive listing reports truncated when >5000 entries
  - No mutation
  """

  alias Tet.Runtime.Tools.PathResolver
  alias Tet.Runtime.Tools.Envelope

  @max_entries 5_000
  @max_depth_limit 12
  @type result :: Envelope.t()

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
    max_depth = Map.get(args, "max_depth", if(recursive, do: @max_depth_limit, else: 0))

    with :ok <- validate_arg_types(args),
         {:ok, resolved_path} <- PathResolver.resolve_directory(path_str, workspace_root),
         :ok <- contain_realpath(resolved_path, workspace_root) do
      list_entries(resolved_path, path_str, recursive, max_depth, workspace_root)
    else
      {:error, denial} -> build_error(denial)
    end
  end

  # Defense-in-depth: realpath check immediately before I/O
  defp contain_realpath(resolved_path, workspace_root) do
    root_canon = PathResolver.canonicalize_workspace_root(workspace_root)
    resolved_exp = Path.expand(resolved_path)

    if String.starts_with?(resolved_exp, root_canon <> "/") or
         resolved_exp == root_canon do
      :ok
    else
      {:error,
       %{
         code: "workspace_escape",
         message: "Path escapes workspace containment boundary",
         kind: "policy_denial",
         retryable: false,
         details: %{path: resolved_path}
       }}
    end
  end

  defp validate_arg_types(args) do
    with :ok <- PathResolver.validate_string(Map.get(args, "path", "."), "path"),
         :ok <- PathResolver.validate_boolean(Map.get(args, "recursive", false), "recursive"),
         :ok <-
           PathResolver.validate_integer(
             Map.get(args, "max_depth", 0),
             "max_depth",
             0,
             @max_depth_limit
           ) do
      :ok
    else
      {:error, denial} -> {:error, denial}
    end
  end

  defp list_entries(dir_path, rel_path, recursive, max_depth, workspace_root) do
    case File.ls(dir_path) do
      {:ok, names} ->
        {entries, entry_count, truncated} =
          if recursive and max_depth > 0 do
            collect_recursive(names, dir_path, rel_path, workspace_root, 0, max_depth, [])
          else
            total_names = length(names)
            truncated = total_names > @max_entries
            entries = build_entries(names, dir_path, rel_path, workspace_root, 0, 0, %{})
            entries = if truncated, do: Enum.take(entries, @max_entries), else: entries
            {entries, min(length(entries), @max_entries), truncated}
          end

        summary = %{
          entry_count: entry_count,
          file_count: Enum.count(entries, &(&1.type == "file")),
          directory_count: Enum.count(entries, &(&1.type == "directory")),
          total_bytes: Enum.reduce(entries, 0, &(&1.size_bytes + &2)),
          truncated: truncated
        }

        build_success(rel_path, entries, truncated, summary)

      {:error, :enoent} ->
        build_error(%{
          code: "not_found",
          message: "Directory not found: #{rel_path}",
          kind: "not_found",
          retryable: false,
          details: %{path: rel_path}
        })

      {:error, :eacces} ->
        build_error(%{
          code: "permission_denied",
          message: "Permission denied listing directory",
          kind: "permission",
          retryable: false,
          details: %{path: rel_path}
        })

      {:error, reason} ->
        build_error(%{
          code: "internal_error",
          message: "Failed to list directory: #{reason}",
          kind: "internal",
          retryable: true,
          details: %{path: rel_path}
        })
    end
  end

  defp collect_recursive(_names, _dir_path, _rel_path, _workspace_root, _depth, _max_depth, acc)
       when length(acc) >= @max_entries do
    {Enum.reverse(acc), @max_entries, true}
  end

  defp collect_recursive(_names, _dir_path, _rel_path, _workspace_root, depth, max_depth, acc)
       when depth > max_depth do
    {acc, length(acc), false}
  end

  defp collect_recursive(names, dir_path, rel_path, workspace_root, depth, max_depth, acc) do
    entries = build_entries(names, dir_path, rel_path, workspace_root, depth, 0, %{})
    all_acc = acc ++ entries

    if length(all_acc) >= @max_entries do
      {Enum.take(all_acc, @max_entries), @max_entries, true}
    else
      dirs = Enum.filter(entries, &(&1.type == "directory"))

      sub_results =
        Enum.reduce_while(dirs, {all_acc, false, false}, fn dir,
                                                            {inner_acc, _trunc, _skip} = state ->
          if length(inner_acc) >= @max_entries do
            {:halt, {Enum.take(inner_acc, @max_entries), true, true}}
          else
            sub_path = Path.join(rel_path, Path.basename(dir.path))
            sub_full = Path.join(dir_path, Path.basename(dir.path))

            case File.ls(sub_full) do
              {:ok, sub_names} ->
                {result_acc, _t, result_trunc} =
                  collect_recursive(
                    sub_names,
                    sub_full,
                    sub_path,
                    workspace_root,
                    depth + 1,
                    max_depth,
                    []
                  )

                new_acc = inner_acc ++ result_acc
                truncated = elem(state, 1) || result_trunc || length(new_acc) >= @max_entries
                new_acc_t = if truncated, do: Enum.take(new_acc, @max_entries), else: new_acc
                {:cont, {new_acc_t, truncated, false}}

              {:error, _reason} ->
                {:cont, state}
            end
          end
        end)

      {final_entries, truncated, _} = sub_results
      {final_entries, length(final_entries), truncated}
    end
  end

  defp build_entries(names, dir_path, rel_path, workspace_root, depth, _acc_count, _parents_seen) do
    # Normalize rel_path: strip leading "./" so paths are clean
    normalized_rel = String.replace_prefix(rel_path, "./", "")

    names
    |> Enum.sort()
    |> Enum.reduce([], fn name, acc ->
      if length(acc) >= @max_entries do
        acc
      else
        full = Path.join(dir_path, name)

        entry_rel =
          if normalized_rel == "." or normalized_rel == "" do
            name
          else
            Path.join(normalized_rel, name)
          end

        case entry_type(full, entry_rel, workspace_root) do
          {:ok, type, size} ->
            [
              %{path: entry_rel, type: type, size_bytes: size, depth: depth, redacted: false}
              | acc
            ]

          {:skip, _reason} ->
            [%{path: entry_rel, type: "other", size_bytes: 0, depth: depth, redacted: true} | acc]
        end
      end
    end)
    |> Enum.reverse()
  end

  defp entry_type(full_path, entry_rel, workspace_root) do
    case File.lstat(full_path) do
      {:ok, stat} ->
        case stat.type do
          :directory ->
            {:ok, "directory", 0}

          :regular ->
            {:ok, "file", stat.size}

          :symlink ->
            # Check if the symlink is safe using the entry's relative context
            # We use entry_rel as the path to resolve since it's workspace-relative
            case PathResolver.resolve(entry_rel, workspace_root) do
              {:ok, _} -> {:ok, "symlink", stat.size}
              {:error, _} -> {:skip, :escape}
            end

          _ ->
            {:ok, "other", 0}
        end

      {:error, _reason} ->
        {:ok, "other", 0}
    end
  end

  defp build_success(rel_path, entries, truncated, summary) do
    data = %{
      directory: rel_path,
      entries: entries,
      summary: summary
    }

    Envelope.success(data,
      truncated: truncated,
      limit_usage: %{
        paths: %{used: 1, max: @max_entries},
        results: %{used: length(entries), max: @max_entries}
      }
    )
  end

  defp build_error(denial) do
    Envelope.error(denial,
      limit_usage: %{
        paths: %{used: 0, max: @max_entries},
        results: %{used: 0, max: @max_entries}
      }
    )
  end
end
