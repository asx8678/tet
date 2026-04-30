defmodule Tet.Runtime.Tools.PathResolver do
  @moduledoc """
  Resolves workspace-relative paths and enforces containment.

  Every read-only tool path must pass through `resolve/2` before any
  filesystem operation. The resolver rejects:

  - Absolute paths (no leading `/`)
  - Path traversal components (`..`)
  - NUL bytes, symlink escapes (realpath outside workspace)
  - Denied globs (future: configurable deny list)

  Returns structured denial reasons matching the common error schema
  from `BD-0020`.
  """

  @type denial :: %{
          required(:code) => binary(),
          required(:message) => binary(),
          required(:kind) => binary(),
          required(:retryable) => boolean(),
          optional(:details) => map()
        }

  @type resolve_result :: {:ok, Path.t()} | {:error, denial()}

  @doc """
  Resolves a workspace-relative path string against a workspace root.

  Returns `{:ok, absolute_path}` when the path is safe and contained,
  or `{:error, denial}` when it violates containment rules.

  ## Examples

      iex> PathResolver.resolve("/etc/passwd", "/workspace")
      {:error, %{code: "workspace_escape", ...}}

      iex> PathResolver.resolve("../other", "/workspace")
      {:error, %{code: "workspace_escape", ...}}

      iex> PathResolver.resolve("lib/foo.ex", "/workspace")
      {:ok, "/workspace/lib/foo.ex"}
  """
  @spec resolve(String.t(), Path.t()) :: resolve_result()
  def resolve(path_str, workspace_root) when is_binary(path_str) do
    with :ok <- reject_null_bytes(path_str),
         :ok <- reject_absolute(path_str),
         :ok <- reject_traversal(path_str),
         {:ok, joined} <- join_relative(path_str, workspace_root),
         :ok <- reject_realpath_escape(joined, workspace_root) do
      {:ok, joined}
    end
  end

  @doc """
  Resolves a path that is expected to be a directory.

  Same as `resolve/2` plus a directory-existence check.
  """
  @spec resolve_directory(String.t(), Path.t()) :: resolve_result()
  def resolve_directory(path_str, workspace_root) do
    with {:ok, resolved} <- resolve(path_str, workspace_root) do
      case File.dir?(resolved) do
        true -> {:ok, resolved}
        false -> {:error, not_directory_denial(path_str)}
      end
    end
  end

  @doc """
  Resolves a path that is expected to be a file.

  Same as `resolve/2` plus a file-existence check.
  """
  @spec resolve_file(String.t(), Path.t()) :: resolve_result()
  def resolve_file(path_str, workspace_root) do
    with {:ok, resolved} <- resolve(path_str, workspace_root) do
      case File.regular?(resolved) do
        true ->
          {:ok, resolved}

        false ->
          if File.exists?(resolved) do
            {:error, not_file_denial(path_str)}
          else
            {:error, not_found_denial(path_str)}
          end
      end
    end
  end

  @doc """
  Returns `true` if the path is lexically contained within the workspace root.
  """
  @spec contained?(Path.t(), Path.t()) :: boolean()
  def contained?(resolved_path, workspace_root) do
    resolved = Path.expand(resolved_path)
    root = Path.expand(workspace_root)

    String.starts_with?(resolved, root <> "/") or resolved == root
  end

  # --- Rejection helpers ---

  defp reject_null_bytes(path) do
    if String.contains?(path, <<0>>) do
      {:error, invalid_path_denial("Path contains null bytes")}
    else
      :ok
    end
  end

  defp reject_absolute(path) do
    cond do
      String.starts_with?(path, "/") ->
        {:error, workspace_escape_denial("Absolute paths are not allowed")}

      String.match?(path, ~r/^[A-Za-z]:\\/) ->
        {:error, workspace_escape_denial("Windows absolute paths are not allowed")}

      true ->
        :ok
    end
  end

  defp reject_traversal(path) do
    components = path |> String.split("/") |> Enum.reject(&(&1 == "" or &1 == "."))

    if Enum.any?(components, &(&1 == "..")) do
      {:error, workspace_escape_denial("Path traversal ('..') is not allowed")}
    else
      :ok
    end
  end

  defp join_relative(path_str, workspace_root) do
    joined = Path.join(workspace_root, path_str) |> Path.expand()

    if String.starts_with?(joined, workspace_root |> Path.expand() |> then(&(&1 <> "/"))) or
         joined == Path.expand(workspace_root) do
      {:ok, joined}
    else
      {:error, workspace_escape_denial("Resolved path escapes workspace")}
    end
  end

  defp reject_realpath_escape(resolved_path, workspace_root) do
    case File.lstat(resolved_path) do
      {:ok, stat} ->
        if stat.type == :symlink do
          case File.read_link(resolved_path) do
            {:ok, target} ->
              parent_dir = Path.dirname(resolved_path)
              absolute_target = Path.absname(target, parent_dir) |> Path.expand()

              contained? =
                String.starts_with?(absolute_target, Path.expand(workspace_root) <> "/") or
                  absolute_target == Path.expand(workspace_root)

              if contained? do
                :ok
              else
                {:error, workspace_escape_denial("Symlink target escapes workspace")}
              end

            {:error, _reason} ->
              :ok
          end
        else
          :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  # --- Denial builders ---

  defp workspace_escape_denial(message) do
    %{
      code: "workspace_escape",
      message: message,
      kind: "policy_denial",
      retryable: false,
      details: %{}
    }
  end

  defp invalid_path_denial(message) do
    %{
      code: "invalid_arguments",
      message: message,
      kind: "invalid_input",
      retryable: false,
      details: %{}
    }
  end

  defp not_found_denial(path) do
    %{
      code: "not_found",
      message: "File not found: #{path}",
      kind: "not_found",
      retryable: false,
      details: %{path: path}
    }
  end

  defp not_file_denial(path) do
    %{
      code: "not_file",
      message: "Path is not a regular file: #{path}",
      kind: "invalid_input",
      retryable: false,
      details: %{path: path}
    }
  end

  defp not_directory_denial(path) do
    %{
      code: "not_directory",
      message: "Path is not a directory: #{path}",
      kind: "not_found",
      retryable: false,
      details: %{path: path}
    }
  end
end
