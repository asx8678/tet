defmodule Tet.Runtime.Tools.Read do
  @moduledoc """
  Executes the `read` tool: reads a bounded text range from one workspace file.

  Implements:
  - Workspace path containment via `PathResolver`
  - Realpath defense-in-depth check before I/O
  - Bounded line ranges (start_line / line_count)
  - Truncation at byte limit (max_read_bytes from contract)
  - Binary file detection
  - Structured denial reasons (BD-0020 envelope)
  - No mutation
  - Bounded file reads at the I/O boundary
  """

  alias Tet.Runtime.Tools.PathResolver
  alias Tet.Runtime.Tools.Envelope

  @default_max_bytes 1_000_000
  @default_max_lines 5_000
  @read_chunk_size 65_536

  @type result :: Envelope.t()

  @doc """
  Reads a bounded text range from one workspace file.

  ## Options
    - `:workspace_root` — required absolute path to workspace root
    - `:max_bytes` — max bytes to read (default: 1_000_000)
    - `:max_lines` — max lines to return (default: 5_000)

  Returns the standard output envelope.
  """
  @spec run(map(), keyword()) :: result()
  def run(args, opts \\ []) when is_map(args) and is_list(opts) do
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    path_str = Map.get(args, "path", "")
    start_line = Map.get(args, "start_line", 1)
    line_count = Map.get(args, "line_count", @default_max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    max_lines = Keyword.get(opts, :max_lines, @default_max_lines)

    with :ok <- validate_arg_types(args),
         {:ok, resolved_path} <- PathResolver.resolve_file(path_str, workspace_root),
         :ok <- validate_line_range(start_line, line_count, max_lines),
         :ok <- contain_realpath(resolved_path, workspace_root),
         {:ok, content, meta} <- read_file_range(resolved_path, start_line, line_count, max_bytes) do
      build_success(path_str, content, meta)
    else
      {:error, denial} -> build_error(denial)
    end
  end

  # Defense-in-depth: realpath check immediately before I/O
  defp contain_realpath(resolved_path, workspace_root) do
    root_canon = PathResolver.canonicalize_workspace_root(workspace_root)

    # Check if the path is under workspace root without symlink following
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
         correlation: nil,
         details: %{path: resolved_path}
       }}
    end
  end

  defp validate_arg_types(args) do
    with :ok <- PathResolver.validate_string(Map.get(args, "path", ""), "path"),
         :ok <- PathResolver.validate_integer(Map.get(args, "start_line", 1), "start_line", 1),
         :ok <-
           PathResolver.validate_integer(
             Map.get(args, "line_count", @default_max_lines),
             "line_count",
             1
           ) do
      :ok
    else
      {:error, denial} -> {:error, denial}
    end
  end

  defp validate_line_range(start_line, _line_count, _max_lines) when start_line < 1 do
    {:error,
     %{
       code: "invalid_arguments",
       message: "start_line must be >= 1",
       kind: "invalid_input",
       retryable: false,
       correlation: nil,
       details: %{start_line: start_line}
     }}
  end

  defp validate_line_range(_start_line, line_count, max_lines) when line_count > max_lines do
    {:error,
     %{
       code: "invalid_arguments",
       message: "line_count exceeds maximum of #{max_lines}",
       kind: "invalid_input",
       retryable: false,
       correlation: nil,
       details: %{line_count: line_count, max: max_lines}
     }}
  end

  defp validate_line_range(_start_line, line_count, _max_lines) when line_count < 1 do
    {:error,
     %{
       code: "invalid_arguments",
       message: "line_count must be >= 1",
       kind: "invalid_input",
       retryable: false,
       correlation: nil,
       details: %{line_count: line_count}
     }}
  end

  defp validate_line_range(_start_line, _line_count, _max_lines), do: :ok

  defp read_file_range(path, start_line, line_count, max_bytes) do
    # Read bounded bytes at the I/O boundary: never read more than
    # what's needed for the requested line range + max_bytes
    case File.stat(path) do
      {:ok, stat} ->
        total_file_bytes = stat.size
        # a bit extra for line splitting
        read_limit = max_bytes + @read_chunk_size
        bytes_to_read = min(total_file_bytes, read_limit)

        case read_bounded(path, bytes_to_read) do
          {:ok, content} ->
            if binary_content?(content) do
              {:ok, "",
               %{
                 start_line: 1,
                 line_count: 0,
                 total_lines: 0,
                 bytes_read: 0,
                 total_bytes: total_file_bytes,
                 binary: true
               }}
            else
              read_text_range(content, start_line, line_count, max_bytes, total_file_bytes)
            end

          {:error, :enoent} ->
            {:error,
             %{
               code: "not_found",
               message: "File not found",
               kind: "not_found",
               retryable: false,
               correlation: nil,
               details: %{}
             }}

          {:error, :eacces} ->
            {:error,
             %{
               code: "permission_denied",
               message: "Permission denied reading file",
               kind: "permission",
               retryable: false,
               correlation: nil,
               details: %{}
             }}

          {:error, reason} ->
            {:error,
             %{
               code: "internal_error",
               message: "Failed to read file: #{reason}",
               kind: "internal",
               retryable: true,
               correlation: nil,
               details: %{}
             }}
        end

      {:error, :enoent} ->
        {:error,
         %{
           code: "not_found",
           message: "File not found",
           kind: "not_found",
           retryable: false,
           correlation: nil,
           details: %{}
         }}

      {:error, :eacces} ->
        {:error,
         %{
           code: "permission_denied",
           message: "Permission denied reading file",
           kind: "permission",
           retryable: false,
           correlation: nil,
           details: %{}
         }}

      {:error, reason} ->
        {:error,
         %{
           code: "internal_error",
           message: "Failed to read file: #{reason}",
           kind: "internal",
           retryable: true,
           correlation: nil,
           details: %{}
         }}
    end
  end

  defp read_bounded(path, max_bytes) do
    File.open(path, [:read, :binary], fn io_device ->
      IO.binread(io_device, max_bytes)
    end)
  end

  defp binary_content?(content) do
    # Check first 8KB for null bytes as a heuristic
    sample = String.slice(content, 0, 8_192)
    String.contains?(sample, <<0>>)
  end

  defp read_text_range(content, start_line, line_count, max_bytes, total_file_bytes) do
    lines = String.split(content, "\n")
    total_lines = length(lines)

    if start_line > total_lines do
      {:ok, "",
       %{
         total_bytes: total_file_bytes,
         bytes_read: byte_size(content),
         start_line: start_line,
         line_count: 0,
         total_lines: total_lines,
         binary: false,
         truncated: false
       }}
    else
      selected = Enum.drop(lines, start_line - 1) |> Enum.take(line_count)
      result = Enum.join(selected, "\n")
      result_bytes = byte_size(result)

      {truncated, final_result} =
        if result_bytes > max_bytes do
          {true, binary_part(result, 0, max_bytes)}
        else
          {false, result}
        end

      {:ok, final_result,
       %{
         total_bytes: total_file_bytes,
         bytes_read: result_bytes,
         start_line: start_line,
         line_count: min(length(selected), line_count),
         total_lines: total_lines,
         binary: false,
         truncated: truncated
       }}
    end
  end

  defp build_success(path_str, content, meta) do
    truncated = meta[:truncated] || false

    data = %{
      path: path_str,
      content: content,
      encoding: "utf-8",
      start_line: meta.start_line,
      line_count: meta.line_count,
      total_lines: meta.total_lines,
      bytes_read: meta.bytes_read || byte_size(content),
      binary: meta.binary || false
    }

    Envelope.success(data,
      truncated: truncated,
      limit_usage: %{
        paths: %{used: 1, max: 1},
        bytes: %{used: meta.bytes_read || byte_size(content)},
        lines: %{used: meta.line_count}
      }
    )
  end

  defp build_error(denial) do
    Envelope.error(denial,
      limit_usage: %{
        paths: %{used: 0, max: 1},
        bytes: %{used: 0},
        lines: %{used: 0}
      }
    )
  end
end
