defmodule Tet.Runtime.Tools.Search do
  @moduledoc """
  Executes the `search` tool: searches bounded text files under a workspace path.

  Uses ripgrep (`rg`) via a streaming Port for bounded text search with
  structured results. Implements:
  - Workspace path containment via `PathResolver`
  - Regex and literal search modes (safe from query injection)
  - Case-sensitive and case-insensitive options
  - Include/exclude glob patterns
  - Streaming Port-based I/O with real-time limit enforcement
  - Match count, unique path, and byte limits with early kill
  - Structured denial reasons (BD-0020)
  - No mutation
  - RIPGREP_CONFIG_PATH isolation
  """

  alias Tet.Runtime.Tools.PathResolver

  @max_matches 200
  @max_paths 100
  @rg_timeout 10_000
  @max_output_bytes 5_000_000
  @max_snippet_bytes 8_192

  @doc """
  Searches bounded text files under a workspace path.

  ## Options
    - `:workspace_root` — required absolute path to workspace root

  ## Args
    - `path` — workspace-relative directory or file path to search
    - `query` — literal text or regex pattern
    - `regex` — treat query as regular expression (default: false)
    - `case_sensitive` — case-sensitive matching (default: true)
    - `include_globs` — optional allowlist glob patterns
    - `exclude_globs` — optional denylist glob patterns
  """
  @spec run(map(), keyword()) :: map()
  def run(args, opts \\ []) when is_map(args) and is_list(opts) do
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    path_str = Map.get(args, "path", ".")
    query = Map.get(args, "query", "")
    regex = Map.get(args, "regex", false)
    case_sensitive = Map.get(args, "case_sensitive", true)
    include_globs = Map.get(args, "include_globs", [])
    exclude_globs = Map.get(args, "exclude_globs", [])

    with :ok <- validate_arg_types(args),
         :ok <- validate_query(query),
         {:ok, resolved_path} <- PathResolver.resolve(path_str, workspace_root),
         :ok <- require_resolved_exists(resolved_path, path_str) do
      do_search(
        resolved_path,
        path_str,
        query,
        regex,
        case_sensitive,
        include_globs,
        exclude_globs,
        workspace_root
      )
    else
      {:error, denial} -> build_error(denial)
    end
  end

  # --- Pre-I/O validation ---

  defp require_resolved_exists(resolved_path, path_str) do
    cond do
      File.exists?(resolved_path) ->
        :ok

      File.lstat(resolved_path) == {:error, :enoent} ->
        {:error,
         %{
           code: "not_found",
           message: "Search path not found: #{path_str}",
           kind: "not_found",
           retryable: false,
           details: %{path: path_str}
         }}

      true ->
        :ok
    end
  end

  defp validate_arg_types(args) do
    with :ok <- PathResolver.validate_string(Map.get(args, "path", "."), "path"),
         :ok <- PathResolver.validate_string(Map.get(args, "query", ""), "query"),
         :ok <- PathResolver.validate_boolean(Map.get(args, "regex", false), "regex"),
         :ok <-
           PathResolver.validate_boolean(
             Map.get(args, "case_sensitive", true),
             "case_sensitive"
           ),
         :ok <-
           PathResolver.validate_glob_list(Map.get(args, "include_globs", []), "include_globs"),
         :ok <-
           PathResolver.validate_glob_list(Map.get(args, "exclude_globs", []), "exclude_globs") do
      :ok
    else
      {:error, denial} -> {:error, denial}
    end
  end

  defp validate_query(query) do
    cond do
      not is_binary(query) ->
        {:error,
         %{
           code: "invalid_arguments",
           message: "query must be a string",
           kind: "invalid_input",
           retryable: false,
           details: %{}
         }}

      query == "" ->
        {:error,
         %{
           code: "invalid_arguments",
           message: "query must be a non-empty string",
           kind: "invalid_input",
           retryable: false,
           details: %{}
         }}

      String.contains?(query, <<0>>) ->
        {:error,
         %{
           code: "invalid_arguments",
           message: "query must not contain null bytes",
           kind: "invalid_input",
           retryable: false,
           details: %{}
         }}

      byte_size(query) > 4_096 ->
        {:error,
         %{
           code: "invalid_arguments",
           message: "query exceeds maximum length of 4096 bytes",
           kind: "invalid_input",
           retryable: false,
           details: %{max_bytes: 4_096}
         }}

      true ->
        :ok
    end
  end

  # --- Main search dispatch ---

  defp do_search(
         search_path,
         _rel_path,
         query,
         regex,
         case_sensitive,
         include_globs,
         exclude_globs,
         workspace_root
       ) do
    rg_args =
      build_rg_args(search_path, query, regex, case_sensitive, include_globs, exclude_globs)

    case run_rg_streaming(rg_args) do
      {:ok, raw_matches, truncated} ->
        parse_and_package(raw_matches, workspace_root, truncated)

      {:error, :rg_not_found} ->
        build_error(%{
          code: "tool_unavailable",
          message: "ripgrep (rg) is not installed.",
          kind: "unavailable",
          retryable: true,
          details: %{}
        })

      {:error, :rg_timeout} ->
        build_error(%{
          code: "timeout",
          message: "Search timed out after #{@rg_timeout}ms",
          kind: "timeout",
          retryable: true,
          details: %{timeout_ms: @rg_timeout}
        })

      {:error, :rg_error, stderr} ->
        if is_binary(stderr) and
             (String.contains?(stderr, "error parsing regex") or
                String.contains?(stderr, "regex parse error")) do
          build_error(%{
            code: "invalid_arguments",
            message: "Invalid regex pattern: #{String.trim(stderr)}",
            kind: "invalid_input",
            retryable: false,
            details: %{}
          })
        else
          build_error(%{
            code: "internal_error",
            message: "Search failed: #{String.trim(stderr)}",
            kind: "internal",
            retryable: true,
            details: %{}
          })
        end

      {:error, reason} ->
        build_error(%{
          code: "internal_error",
          message: "Search failed: #{reason}",
          kind: "internal",
          retryable: true,
          details: %{}
        })
    end
  end

  # --- rg args building (injection-safe) ---

  defp build_rg_args(search_path, query, regex, case_sensitive, include_globs, exclude_globs) do
    args = [
      "--json",
      "--max-count",
      "200",
      "--max-filesize",
      "1M",
      "--no-ignore",
      "--color",
      "never",
      "--no-config",
      "--no-follow",
      "--no-pre"
    ]

    args = if case_sensitive, do: args, else: args ++ ["-i"]

    args =
      Enum.reduce(include_globs, args, fn glob, acc ->
        acc ++ ["--glob", glob]
      end)

    args =
      Enum.reduce(exclude_globs, args, fn glob, acc ->
        acc ++ ["--glob", "!#{glob}"]
      end)

    # Always use -e (--regexp) to pass the query as the pattern argument,
    # so the query can never be interpreted as a flag. For literal mode,
    # combine with --fixed-strings. The `--` protects the search path.
    pattern_args =
      if regex do
        ["-e", query]
      else
        ["--fixed-strings", "-e", query]
      end

    args ++ pattern_args ++ ["--", to_string(search_path)]
  end

  # --- Port-based streaming ---

  defp run_rg_streaming(args) do
    rg_path = System.find_executable("rg")

    if rg_path == nil do
      {:error, :rg_not_found}
    else
      task =
        Task.async(fn ->
          port =
            Port.open({:spawn_executable, rg_path}, [
              {:args, args},
              {:env, [{~c"RIPGREP_CONFIG_PATH", ~c""}]},
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout
            ])

          read_port_stream(port, %{
            buffer: <<>>,
            matches: [],
            seen_paths: MapSet.new(),
            bytes_read: 0,
            truncated: false,
            stderr: <<>>
          })
        end)

      case Task.yield(task, @rg_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :rg_timeout}
      end
    end
  end

  defp read_port_stream(port, state) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        new_state = process_data_chunk(data, state)

        cond do
          new_state.truncated ->
            Port.close(port)
            drain_port_after_kill(port)
            {:ok, Enum.reverse(new_state.matches), true}

          new_state.bytes_read >= @max_output_bytes ->
            Port.close(port)
            drain_port_after_kill(port)
            {:ok, Enum.reverse(new_state.matches), true}

          true ->
            read_port_stream(port, new_state)
        end

      {^port, {:exit_status, code}} ->
        final_state = flush_buffer(state)

        cond do
          code == 2 ->
            # rg error — return stderr content
            {:error, :rg_error, final_state.stderr}

          code in [0, 1] ->
            {:ok, Enum.reverse(final_state.matches), final_state.truncated}

          true ->
            truncated = final_state.truncated or true
            {:ok, Enum.reverse(final_state.matches), truncated}
        end
    end
  end

  defp process_data_chunk(data, state) do
    # Append to buffer and split on newlines
    buffer = state.buffer <> data
    lines = String.split(buffer, "\n")

    # All complete lines except the last (possibly partial) one
    {complete, incomplete} =
      case List.pop_at(lines, -1) do
        {<<>>, rest} -> {rest, <<>>}
        {last, rest} -> {rest, last}
      end

    # Process each complete JSON line
    Enum.reduce(complete, %{state | buffer: incomplete}, fn line, acc ->
      if acc.truncated do
        acc
      else
        process_json_line(line, acc)
      end
    end)
  end

  defp process_json_line(line, state) do
    line_bytes = byte_size(line)
    new_bytes = state.bytes_read + line_bytes

    cond do
      new_bytes > @max_output_bytes ->
        %{state | bytes_read: new_bytes, truncated: true}

      length(state.matches) >= @max_matches ->
        %{state | bytes_read: new_bytes, truncated: true}

      true ->
        decoded = try_decode_json(line)

        if is_map(decoded) && Map.get(decoded, "type") == "match" do
          path = get_in(decoded, ["data", "path", "text"]) || ""
          new_seen = MapSet.put(state.seen_paths, path)

          if MapSet.size(new_seen) > @max_paths do
            %{state | bytes_read: new_bytes, truncated: true}
          else
            decoded = cap_snippet_column(decoded)

            %{
              state
              | bytes_read: new_bytes,
                matches: [decoded | state.matches],
                seen_paths: new_seen
            }
          end
        else
          # Non-JSON line (likely stderr) — accumulate as error output
          %{state | bytes_read: new_bytes, stderr: state.stderr <> line <> "\n"}
        end
    end
  end

  defp try_decode_json(line) do
    # :json.decode/1 raises on invalid input; rescue gracefully
    try do
      :json.decode(line)
    rescue
      _ -> nil
    end
  end

  defp cap_snippet_column(match) do
    submatches = get_in(match, ["data", "submatches"]) || []

    capped =
      Enum.map(submatches, fn sm ->
        start_col = Map.get(sm, "start", 0)
        end_col = Map.get(sm, "end", 0)

        sm
        |> Map.put("start", min(start_col, @max_snippet_bytes))
        |> Map.put("end", min(end_col, @max_snippet_bytes))
      end)

    put_in(match, ["data", "submatches"], capped)
  end

  defp flush_buffer(state) do
    if state.buffer != <<>> do
      process_json_line(state.buffer, state)
    else
      state
    end
  end

  defp drain_port_after_kill(port) do
    receive do
      {^port, _msg} -> drain_port_after_kill(port)
      {:Port, _msg} -> :ok
    after
      100 -> :ok
    end
  end

  # --- Parse and package ---

  defp parse_and_package(raw_matches, workspace_root, io_truncated) do
    {matches, truncated_at_match} =
      if length(raw_matches) > @max_matches do
        {Enum.take(raw_matches, @max_matches), true}
      else
        {raw_matches, false}
      end

    truncated = truncated_at_match || io_truncated

    file_count =
      matches
      |> Enum.map(fn m -> get_in(m, ["data", "path", "text"]) || "" end)
      |> Enum.uniq()
      |> length()

    result_matches =
      Enum.map(matches, fn m ->
        path_text = get_in(m, ["data", "path", "text"]) || ""
        line_number = get_in(m, ["data", "line_number"]) || 1
        submatches = get_in(m, ["data", "submatches"]) || []
        lines_content = get_in(m, ["data", "lines", "text"]) || ""

        first_col =
          case submatches do
            [first | _] -> get_in(first, ["start"]) || 1
            _ -> 1
          end

        entry_rel = relativize(path_text, workspace_root)

        snippet =
          lines_content
          |> binary_part_or_all(0, min(byte_size(lines_content), @max_snippet_bytes))
          |> String.trim_trailing("\n")

        %{
          path: entry_rel,
          line: line_number,
          column: first_col + 1,
          text: snippet,
          redacted: false
        }
      end)

    build_success(result_matches, truncated, %{
      match_count: length(result_matches),
      file_count: file_count,
      truncated: truncated
    })
  end

  defp binary_part_or_all(binary, start, length) do
    total = byte_size(binary)

    if start >= total do
      <<>>
    else
      available = total - start
      to_read = min(length, available)
      binary_part(binary, start, to_read)
    end
  end

  defp relativize(absolute_path, workspace_root) do
    root = Path.expand(workspace_root) <> "/"

    case String.starts_with?(absolute_path, root) do
      true -> String.replace_prefix(absolute_path, root, "")
      false -> absolute_path
    end
  end

  defp build_success(matches, truncated, summary) do
    alias Tet.Runtime.Tools.Envelope

    data = %{
      matches: matches,
      summary: Map.merge(summary, %{match_count: length(matches)})
    }

    Envelope.success(data,
      truncated: truncated,
      limit_usage: %{
        paths: %{used: 1, max: @max_paths},
        results: %{used: length(matches), max: @max_matches}
      }
    )
  end

  defp build_error(denial) do
    alias Tet.Runtime.Tools.Envelope

    Envelope.error(denial,
      limit_usage: %{
        paths: %{used: 0, max: @max_paths},
        results: %{used: 0, max: @max_matches}
      }
    )
  end
end
