defmodule Tet.Runtime.Tools.Search do
  @moduledoc """
  Executes the `search` tool: searches bounded text files under a workspace path.

  Uses ripgrep (`rg`) under the hood for fast, bounded text search with
  structured results. Implements:
  - Workspace path containment via `PathResolver`
  - Regex and literal search modes
  - Case-sensitive and case-insensitive options
  - Include/exclude glob patterns
  - Match count and file count truncation
  - Structured denial reasons
  - No mutation
  """

  alias Tet.Runtime.Tools.PathResolver

  @max_matches 200
  @max_paths 100

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

    condensed_denial =
      cond do
        query == "" or query == nil ->
          %{
            code: "invalid_arguments",
            message: "query must be a non-empty string",
            kind: "invalid_input",
            retryable: false,
            details: %{}
          }

        byte_size(query) > 4_096 ->
          %{
            code: "invalid_arguments",
            message: "query exceeds maximum length of 4096 bytes",
            kind: "invalid_input",
            retryable: false,
            details: %{max_bytes: 4_096}
          }

        true ->
          nil
      end

    if condensed_denial do
      build_error(condensed_denial)
    else
      with {:ok, resolved_path} <- PathResolver.resolve(path_str, workspace_root) do
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
  end

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

    case run_rg(rg_args) do
      {:ok, raw_results} ->
        parse_and_package(raw_results, workspace_root)

      {:error, :rg_not_found} ->
        build_error(%{
          code: "tool_unavailable",
          message: "ripgrep (rg) is not installed. Install it with: brew install ripgrep",
          kind: "unavailable",
          retryable: true,
          details: %{}
        })

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

  defp build_rg_args(search_path, query, regex, case_sensitive, include_globs, exclude_globs) do
    args = [
      "--json",
      "--max-count",
      "200",
      "--max-filesize",
      "1M",
      "--no-ignore",
      "--follow",
      "--color",
      "never"
    ]

    args = if regex, do: args, else: args ++ ["--fixed-strings"]
    args = if case_sensitive, do: args, else: args ++ ["-i"]

    args =
      Enum.reduce(include_globs, args, fn glob, acc ->
        acc ++ ["--glob", glob]
      end)

    args =
      Enum.reduce(exclude_globs, args, fn glob, acc ->
        acc ++ ["--glob", "!#{glob}"]
      end)

    args ++ [query, to_string(search_path)]
  end

  defp run_rg(args) do
    case System.find_executable("rg") do
      nil ->
        {:error, :rg_not_found}

      _rg_path ->
        opts = [stderr_to_stdout: true, parallelism: false]

        case System.cmd("rg", args, opts) do
          {output, 0} ->
            parse_rg_json_output(output)

          {output, 1} ->
            parse_rg_json_output(output)

          {_output, 2} ->
            {:error, :rg_error}

          {output, _other} ->
            parse_rg_json_output(output)
        end
    end
  end

  defp parse_rg_json_output(output) do
    matches =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce([], fn line, acc ->
        decoded = :json.decode(line)

        if is_map(decoded) && Map.get(decoded, "type") == "match" do
          [decoded | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    {:ok, matches}
  end

  defp parse_and_package(raw_matches, workspace_root) do
    {matches, truncated_at_match} =
      if length(raw_matches) > @max_matches do
        {Enum.take(raw_matches, @max_matches), true}
      else
        {raw_matches, false}
      end

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

        %{
          path: entry_rel,
          line: line_number,
          column: first_col + 1,
          text: String.trim_trailing(lines_content, "\n"),
          redacted: false
        }
      end)

    build_success(result_matches, truncated_at_match, %{
      match_count: length(result_matches),
      file_count: file_count,
      truncated: truncated_at_match
    })
  end

  defp relativize(absolute_path, workspace_root) do
    root = Path.expand(workspace_root) <> "/"

    case String.starts_with?(absolute_path, root) do
      true -> String.replace_prefix(absolute_path, root, "")
      false -> absolute_path
    end
  end

  defp build_success(matches, truncated, summary) do
    %{
      ok: true,
      data: %{
        matches: matches,
        summary: Map.merge(summary, %{match_count: length(matches)})
      },
      truncated: truncated,
      limit_usage: %{
        paths: %{used: 1, max: @max_paths},
        results: %{used: length(matches), max: @max_matches}
      }
    }
  end

  defp build_error(denial) do
    %{
      ok: false,
      error: denial,
      truncated: false,
      limit_usage: %{
        paths: %{used: 0, max: @max_paths},
        results: %{used: 0, max: @max_matches}
      }
    }
  end
end
