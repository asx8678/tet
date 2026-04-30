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
    workspace_root = canonicalize_workspace_root(workspace_root)

    with :ok <- reject_null_bytes(path_str),
         :ok <- reject_absolute(path_str),
         :ok <- reject_traversal(path_str),
         {:ok, joined} <- join_relative(path_str, workspace_root),
         :ok <- reject_symlink_chain_escape(joined, workspace_root) do
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
    root = canonicalize_workspace_root(workspace_root)

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

  defp canonicalize_workspace_root(workspace_root) do
    case File.lstat(workspace_root) do
      {:ok, stat} ->
        if stat.type == :symlink do
          case File.read_link(workspace_root) do
            {:ok, target} ->
              absolute_target =
                Path.absname(target, Path.dirname(workspace_root)) |> Path.expand()

              absolute_target

            {:error, _reason} ->
              Path.expand(workspace_root)
          end
        else
          Path.expand(workspace_root)
        end

      {:error, _reason} ->
        Path.expand(workspace_root)
    end
  end

  defp join_relative(path_str, workspace_root) do
    joined = Path.join(workspace_root, path_str) |> Path.expand()

    if String.starts_with?(joined, workspace_root <> "/") or
         joined == workspace_root do
      {:ok, joined}
    else
      {:error, workspace_escape_denial("Resolved path escapes workspace")}
    end
  end

  @doc false
  def reject_symlink_chain_escape(resolved_path, workspace_root) do
    # Walk each path component and check for intermediate symlink escapes
    # Use the already-canonicalized workspace_root here
    root = canonicalize_workspace_root(workspace_root)
    components = path_components(resolved_path, root)

    check_components_for_symlink_escape(components, root)
  end

  defp path_components(resolved_path, root) do
    # Build list of component paths from root down to resolved_path
    relative =
      case String.starts_with?(resolved_path, root <> "/") do
        true ->
          String.replace_prefix(resolved_path, root <> "/", "")

        false ->
          if resolved_path == root do
            ""
          else
            resolved_path
          end
      end

    if relative == "" do
      []
    else
      parts = String.split(relative, "/")

      Enum.reduce(parts, [], fn part, acc ->
        prev = if acc == [], do: root, else: List.last(acc)
        [prev <> "/" <> part | acc]
      end)
      |> Enum.reverse()
    end
  end

  defp check_components_for_symlink_escape([], _root), do: :ok

  defp check_components_for_symlink_escape([component | rest], root) do
    case File.lstat(component) do
      {:ok, stat} ->
        if stat.type == :symlink do
          case resolve_symlink_chain(component) do
            {:ok, final_target} ->
              if String.starts_with?(final_target, root <> "/") or
                   final_target == root do
                check_components_for_symlink_escape(rest, root)
              else
                {:error,
                 workspace_escape_denial("Symlink chain from '#{component}' escapes workspace")}
              end

            {:error, _reason} ->
              check_components_for_symlink_escape(rest, root)
          end
        else
          check_components_for_symlink_escape(rest, root)
        end

      {:error, _reason} ->
        # Component doesn't exist yet (path might point to non-existent file)
        check_components_for_symlink_escape(rest, root)
    end
  end

  defp resolve_symlink_chain(path, visited \\ MapSet.new()) do
    if MapSet.member?(visited, path) do
      {:error, :symlink_loop}
    else
      case File.lstat(path) do
        {:ok, stat} ->
          if stat.type == :symlink do
            case File.read_link(path) do
              {:ok, target} ->
                parent_dir = Path.dirname(path)
                absolute_target = Path.absname(target, parent_dir) |> Path.expand()
                resolve_symlink_chain(absolute_target, MapSet.put(visited, path))

              {:error, reason} ->
                {:error, reason}
            end
          else
            {:ok, path}
          end

        {:error, _reason} ->
          {:ok, path}
      end
    end
  end

  # --- Denial builders ---

  def workspace_escape_denial(message) do
    %{
      code: "workspace_escape",
      message: message,
      kind: "policy_denial",
      retryable: false,
      details: %{}
    }
  end

  def invalid_path_denial(message) do
    %{
      code: "invalid_arguments",
      message: message,
      kind: "invalid_input",
      retryable: false,
      details: %{}
    }
  end

  def not_found_denial(path) do
    %{
      code: "not_found",
      message: "File not found: #{path}",
      kind: "not_found",
      retryable: false,
      details: %{path: path}
    }
  end

  def not_file_denial(path) do
    %{
      code: "not_file",
      message: "Path is not a regular file: #{path}",
      kind: "invalid_input",
      retryable: false,
      details: %{path: path}
    }
  end

  def not_directory_denial(path) do
    %{
      code: "not_directory",
      message: "Path is not a directory: #{path}",
      kind: "not_found",
      retryable: false,
      details: %{path: path}
    }
  end

  # Validation helpers

  @doc """
  Validates that a value is a boolean.
  """
  @spec validate_boolean(any(), String.t()) :: :ok | {:error, denial()}
  def validate_boolean(value, field_name) do
    if is_boolean(value) do
      :ok
    else
      {:error,
       %{
         code: "invalid_arguments",
         message: "#{field_name} must be a boolean, got: #{inspect(value)}",
         kind: "invalid_input",
         retryable: false,
         details: %{field: field_name, value: value}
       }}
    end
  end

  @doc """
  Validates that a value is a non-negative integer within an optional range.
  """
  @spec validate_integer(any(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, denial()}
  def validate_integer(value, field_name, min \\ 0, max \\ :infinity) do
    cond do
      not is_integer(value) ->
        {:error,
         %{
           code: "invalid_arguments",
           message: "#{field_name} must be an integer, got: #{inspect(value)}",
           kind: "invalid_input",
           retryable: false,
           details: %{field: field_name, value: value}
         }}

      value < min ->
        {:error,
         %{
           code: "invalid_arguments",
           message: "#{field_name} must be >= #{min}, got: #{value}",
           kind: "invalid_input",
           retryable: false,
           details: %{field: field_name, value: value, min: min}
         }}

      max != :infinity and value > max ->
        {:error,
         %{
           code: "invalid_arguments",
           message: "#{field_name} must be <= #{max}, got: #{value}",
           kind: "invalid_input",
           retryable: false,
           details: %{field: field_name, value: value, max: max}
         }}

      true ->
        :ok
    end
  end

  @doc """
  Validates that a value is a string.
  """
  @spec validate_string(any(), String.t()) :: :ok | {:error, denial()}
  def validate_string(value, field_name) do
    if is_binary(value) do
      :ok
    else
      {:error,
       %{
         code: "invalid_arguments",
         message: "#{field_name} must be a string, got: #{inspect(value)}",
         kind: "invalid_input",
         retryable: false,
         details: %{field: field_name, value: value}
       }}
    end
  end

  @doc """
  Validates that a value is a list of strings (globs).
  """
  @spec validate_glob_list(any(), String.t()) :: :ok | {:error, denial()}
  def validate_glob_list(value, field_name) do
    cond do
      not is_list(value) ->
        {:error,
         %{
           code: "invalid_arguments",
           message: "#{field_name} must be a list, got: #{inspect(value)}",
           kind: "invalid_input",
           retryable: false,
           details: %{field: field_name, value: value}
         }}

      Enum.any?(value, fn item -> not is_binary(item) end) ->
        {:error,
         %{
           code: "invalid_arguments",
           message: "#{field_name} must be a list of strings",
           kind: "invalid_input",
           retryable: false,
           details: %{field: field_name}
         }}

      true ->
        :ok
    end
  end
end
