defmodule Tet.Tool.ReadOnlyContracts do
  @moduledoc """
  Native read-only tool contract catalog for BD-0020.

  These contracts cover repository/file inspection and user clarification only:
  `list`, `read`, `search`, `repo-scan`, `git-diff`, and `ask-user`. They are
  non-mutating manifests for future plan-mode gates and executor layers; they do
  not perform path resolution, file reads, git calls, terminal prompts, logging,
  event persistence, or provider dispatch.
  """

  import Tet.Tool.Schema

  alias Tet.Tool.Contract

  @contract_version "1.0.0"
  @namespace "native.read_only"
  @allowed_modes [:plan, :explore, :execute, :repair]
  @task_categories [:researching, :planning, :acting, :verifying, :debugging, :documenting]
  @source %{
    issue: "BD-0020",
    phase: "Phase 6 — Read-only tool layer",
    spec_sections: ["§13", "§21"],
    references: [
      "/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/__init__.py",
      "/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/file_operations.py",
      "/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/ask_user_question/handler.py"
    ]
  }
  @common_error_codes [
    "invalid_arguments",
    "workspace_escape",
    "path_denied",
    "not_found",
    "not_file",
    "not_directory",
    "permission_denied",
    "binary_file",
    "output_truncated",
    "timeout",
    "tool_unavailable",
    "git_unavailable",
    "not_git_repo",
    "non_interactive",
    "user_cancelled",
    "validation_failed",
    "internal_error"
  ]

  @doc "Returns all native read-only contracts in stable catalog order."
  @spec all() :: [Contract.t()]
  def all do
    [
      list_contract(),
      read_contract(),
      search_contract(),
      repo_scan_contract(),
      git_diff_contract(),
      ask_user_contract()
    ]
  end

  @doc "Returns stable native read-only tool names."
  @spec names() :: [binary()]
  def names, do: Enum.map(all(), & &1.name)

  @doc "Fetches a read-only contract by atom id, string name, or legacy alias."
  @spec fetch(atom() | binary()) ::
          {:ok, Contract.t()} | {:error, {:unknown_read_only_tool_contract, binary()}}
  def fetch(name) when is_atom(name) or is_binary(name) do
    normalized = normalize_name(name)

    case Enum.find(all(), &matches_name?(&1, normalized)) do
      nil -> {:error, {:unknown_read_only_tool_contract, normalized}}
      contract -> {:ok, contract}
    end
  end

  @doc "Validates the static catalog, including duplicate names and aliases."
  @spec validate_catalog() :: :ok | {:error, {:invalid_read_only_tool_catalog, [term()]}}
  def validate_catalog do
    contracts = all()

    errors =
      contracts
      |> Enum.flat_map(&contract_errors/1)
      |> Kernel.++(duplicate_name_errors(contracts))

    if errors == [] do
      :ok
    else
      {:error, {:invalid_read_only_tool_catalog, errors}}
    end
  end

  defp contract_errors(%Contract{} = contract) do
    case Contract.validate(contract) do
      :ok -> []
      {:error, reason} -> [{contract.name, reason}]
    end
  end

  defp duplicate_name_errors(contracts) do
    names = Enum.flat_map(contracts, &[&1.name | &1.aliases])

    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} -> {:duplicate_contract_name, name} end)
  end

  defp matches_name?(%Contract{} = contract, name) do
    name == contract.name or name in contract.aliases
  end

  defp normalize_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace("_", "-")
  end

  defp list_contract do
    contract!(%{
      name: "list",
      aliases: ["list-files", "list_files"],
      title: "List workspace files",
      description:
        "Lists directory entries inside a trusted workspace without reading file contents or mutating state.",
      interactive: false,
      input_schema:
        object_schema(
          "Arguments for listing workspace paths.",
          %{
            "path" => string_property("Workspace-relative directory path to list."),
            "recursive" => boolean_property("Whether to descend into subdirectories.", false),
            "max_depth" =>
              integer_property("Maximum recursive depth requested by the caller.", 0, 12)
          },
          ["path"]
        ),
      output_schema:
        output_schema(
          "Structured bounded directory listing result.",
          object_schema(
            "Directory listing payload.",
            %{
              "directory" => string_property("Canonical workspace-relative directory."),
              "entries" =>
                array_property(
                  "Directory entries in deterministic order.",
                  object_schema(
                    "One directory entry.",
                    %{
                      "path" => string_property("Workspace-relative entry path."),
                      "type" =>
                        enum_property("Entry type.", ["file", "directory", "symlink", "other"]),
                      "size_bytes" => integer_property("File size in bytes, if known.", 0),
                      "depth" => integer_property("Depth relative to requested path.", 0),
                      "redacted" =>
                        boolean_property("True when entry metadata was redacted.", false)
                    },
                    ["path", "type", "size_bytes", "depth", "redacted"]
                  )
                ),
              "summary" =>
                summary_schema(["entry_count", "file_count", "directory_count", "total_bytes"])
            },
            ["directory", "entries", "summary"]
          )
        ),
      limits: limits(5_000, 5_000, 0, 200_000, 30_000),
      redaction: redaction(:workspace_metadata),
      execution: execution([])
    })
  end

  defp read_contract do
    contract!(%{
      name: "read",
      aliases: ["read-file", "read_file"],
      title: "Read workspace file",
      description:
        "Reads a bounded text range from one workspace file after future path policy accepts it.",
      interactive: false,
      input_schema:
        object_schema(
          "Arguments for reading one workspace file.",
          %{
            "path" => string_property("Workspace-relative file path to read."),
            "start_line" => integer_property("One-based first line to include.", 1),
            "line_count" => integer_property("Maximum number of lines to include.", 1, 5_000)
          },
          ["path"]
        ),
      output_schema:
        output_schema(
          "Structured bounded file content result.",
          object_schema(
            "Read-file payload.",
            %{
              "path" => string_property("Canonical workspace-relative file path."),
              "content" => string_property("Redacted text content or selected text range."),
              "encoding" => string_property("Detected or assumed encoding."),
              "start_line" => integer_property("One-based first returned line.", 1),
              "line_count" => integer_property("Returned line count.", 0),
              "total_lines" => integer_property("Total known line count.", 0),
              "bytes_read" => integer_property("Bytes read before redaction/truncation.", 0),
              "binary" => boolean_property("True if the file was summarized as binary.", false)
            },
            [
              "path",
              "content",
              "encoding",
              "start_line",
              "line_count",
              "total_lines",
              "bytes_read",
              "binary"
            ]
          )
        ),
      limits: limits(1, 1, 1_000_000, 200_000, 30_000),
      redaction: redaction(:workspace_content),
      execution: execution([])
    })
  end

  defp search_contract do
    contract!(%{
      name: "search",
      aliases: ["grep", "search-text"],
      title: "Search workspace text",
      description:
        "Searches bounded text files under a workspace path and returns redacted match snippets.",
      interactive: false,
      input_schema:
        object_schema(
          "Arguments for bounded workspace text search.",
          %{
            "path" => string_property("Workspace-relative directory or file path to search."),
            "query" => string_property("Literal text or regex pattern, depending on regex flag."),
            "regex" => boolean_property("Treat query as a regular expression.", false),
            "case_sensitive" => boolean_property("Use case-sensitive matching.", true),
            "include_globs" =>
              array_property(
                "Optional allowlist glob patterns.",
                string_property("Glob pattern.")
              ),
            "exclude_globs" =>
              array_property("Optional denylist glob patterns.", string_property("Glob pattern."))
          },
          ["path", "query"]
        ),
      output_schema:
        output_schema(
          "Structured bounded search result.",
          object_schema(
            "Search payload.",
            %{
              "matches" =>
                array_property(
                  "Search matches in deterministic order.",
                  object_schema(
                    "One search match.",
                    %{
                      "path" => string_property("Workspace-relative file path."),
                      "line" => integer_property("One-based line number.", 1),
                      "column" => integer_property("One-based column number when known.", 1),
                      "text" => string_property("Redacted line snippet."),
                      "redacted" => boolean_property("True if snippet was redacted.", false)
                    },
                    ["path", "line", "text", "redacted"]
                  )
                ),
              "summary" => summary_schema(["match_count", "file_count"])
            },
            ["matches", "summary"]
          )
        ),
      limits: limits(100, 200, 5_000_000, 200_000, 30_000),
      redaction: redaction(:workspace_snippets),
      execution: execution([])
    })
  end

  defp repo_scan_contract do
    contract!(%{
      name: "repo-scan",
      aliases: ["repo_scan"],
      title: "Scan repository shape",
      description:
        "Summarizes repository structure, language hints, and notable files without reading full file bodies.",
      interactive: false,
      input_schema:
        object_schema(
          "Arguments for repository shape scan.",
          %{
            "path" => string_property("Workspace-relative repository root or subdirectory."),
            "sections" =>
              array_property(
                "Optional scan sections to include.",
                enum_property("Scan section.", [
                  "tree",
                  "languages",
                  "package_managers",
                  "tests",
                  "docs"
                ])
              )
          },
          ["path"]
        ),
      output_schema:
        output_schema(
          "Structured bounded repository scan result.",
          object_schema(
            "Repo-scan payload.",
            %{
              "root" => string_property("Canonical workspace-relative scan root."),
              "files" =>
                array_property(
                  "Representative paths only.",
                  string_property("Workspace-relative path.")
                ),
              "languages" =>
                array_property("Detected language labels.", string_property("Language label.")),
              "important_paths" =>
                array_property(
                  "Notable project files.",
                  string_property("Workspace-relative path.")
                ),
              "ignored_paths" =>
                array_property(
                  "Paths hidden by policy or defaults.",
                  string_property("Workspace-relative path.")
                ),
              "summary" => summary_schema(["file_count", "directory_count", "total_bytes"])
            },
            ["root", "files", "languages", "important_paths", "ignored_paths", "summary"]
          )
        ),
      limits: limits(10_000, 1_000, 0, 200_000, 45_000),
      redaction: redaction(:workspace_metadata),
      execution: execution([])
    })
  end

  defp git_diff_contract do
    contract!(%{
      name: "git-diff",
      aliases: ["git_diff", "diff"],
      title: "Inspect git diff",
      description:
        "Returns a bounded read-only git diff summary; no raw git passthrough or mutating flags are allowed.",
      interactive: false,
      input_schema:
        object_schema(
          "Arguments for read-only git diff inspection.",
          %{
            "path" => string_property("Workspace-relative repository path."),
            "base_ref" => string_property("Optional base revision or ref."),
            "target_ref" => string_property("Optional target revision or ref."),
            "paths" =>
              array_property(
                "Optional workspace-relative path filter.",
                string_property("Path filter.")
              ),
            "staged" => boolean_property("Inspect staged changes only.", false),
            "context_lines" => integer_property("Context lines per hunk.", 0, 10)
          },
          ["path"]
        ),
      output_schema:
        output_schema(
          "Structured bounded git diff result.",
          object_schema(
            "Git-diff payload.",
            %{
              "repository" => string_property("Canonical workspace-relative repository path."),
              "base_ref" => string_property("Resolved base revision or ref."),
              "target_ref" => string_property("Resolved target revision or ref."),
              "files" =>
                array_property(
                  "Changed files.",
                  object_schema(
                    "One changed file.",
                    %{
                      "path" => string_property("Workspace-relative file path."),
                      "status" =>
                        enum_property("Git status.", [
                          "added",
                          "modified",
                          "deleted",
                          "renamed",
                          "copied",
                          "unknown"
                        ]),
                      "additions" => integer_property("Added line count.", 0),
                      "deletions" => integer_property("Deleted line count.", 0),
                      "hunks" => integer_property("Returned hunk count.", 0),
                      "redacted" => boolean_property("True when hunks were redacted.", false)
                    },
                    ["path", "status", "additions", "deletions", "hunks", "redacted"]
                  )
                ),
              "summary" => summary_schema(["file_count", "additions", "deletions", "hunk_count"])
            },
            ["repository", "files", "summary"]
          )
        ),
      limits: limits(500, 500, 5_000_000, 200_000, 30_000),
      redaction: redaction(:workspace_diff),
      execution: execution([:reads_git_index])
    })
  end

  defp ask_user_contract do
    contract!(%{
      name: "ask-user",
      aliases: ["ask_user", "ask-user-question", "ask_user_question"],
      title: "Ask operator for clarification",
      description:
        "Prompts the operator for bounded clarification. It is interactive but does not mutate the workspace, shell, or store by itself.",
      interactive: true,
      input_schema:
        object_schema(
          "Arguments for asking bounded operator questions.",
          %{
            "questions" =>
              array_property(
                "Questions to ask in one interaction.",
                object_schema(
                  "One operator question.",
                  %{
                    "header" => string_property("Short unique question label."),
                    "question" => string_property("Question text shown to the operator."),
                    "multi_select" =>
                      boolean_property("Whether multiple options may be selected.", false),
                    "options" =>
                      array_property(
                        "Selectable options.",
                        object_schema(
                          "One selectable option.",
                          %{
                            "label" => string_property("Short option label."),
                            "description" => string_property("Optional option description.")
                          },
                          ["label"]
                        )
                      )
                  },
                  ["header", "question", "options"]
                )
              ),
            "timeout_ms" =>
              integer_property("Interaction timeout requested by caller.", 1_000, 300_000)
          },
          ["questions"]
        ),
      output_schema:
        output_schema(
          "Structured bounded operator-answer result.",
          object_schema(
            "Ask-user payload.",
            %{
              "answers" =>
                array_property(
                  "Operator answers.",
                  object_schema(
                    "One operator answer.",
                    %{
                      "question_header" => string_property("Header of the answered question."),
                      "selected_options" =>
                        array_property(
                          "Selected option labels.",
                          string_property("Option label.")
                        ),
                      "other_text" => nullable_string_property("Optional free-form answer text.")
                    },
                    ["question_header", "selected_options"]
                  )
                ),
              "cancelled" =>
                boolean_property("True when the operator cancelled intentionally.", false),
              "timed_out" => boolean_property("True when the interaction timed out.", false)
            },
            ["answers", "cancelled", "timed_out"]
          )
        ),
      limits: %{
        paths: %{max_count: 0, max_path_bytes: 0, workspace_relative: false},
        results: %{max_questions: 10, max_options_per_question: 6, max_answers: 10},
        bytes: %{max_question_bytes: 4_096, max_answer_bytes: 8_192, max_output_bytes: 32_000},
        timeout_ms: 300_000
      },
      redaction: redaction(:operator_input),
      execution: execution([:operator_interaction])
    })
  end

  defp contract!(attrs) do
    attrs
    |> Map.merge(%{
      namespace: @namespace,
      version: @contract_version,
      read_only: true,
      mutation: :none,
      approval: %{
        required: false,
        reason:
          "Native read-only contract; future gates may still block by mode, task, path, or policy."
      },
      modes: @allowed_modes,
      task_categories: @task_categories,
      error_schema: error_schema(@common_error_codes),
      correlation: correlation(),
      source: @source
    })
    |> Contract.new!()
  end
end
