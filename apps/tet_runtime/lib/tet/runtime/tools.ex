defmodule Tet.Runtime.Tools do
  @moduledoc """
  Facade for the BD-0021 path-safe read-only tool executors.

  Dispatches to the correct tool implementation by name, applies
  workspace containment, enforces limits, and returns structured results.
  """

  @known_tools %{
    "list" => Tet.Runtime.Tools.List,
    "read" => Tet.Runtime.Tools.Read,
    "search" => Tet.Runtime.Tools.Search
  }

  @doc "Returns known read-only tool names."
  @spec known_tool_names() :: [String.t()]
  def known_tool_names, do: Map.keys(@known_tools)

  @doc """
  Runs a named tool with the given arguments and workspace context.

  Returns a structured result map with `ok`, `data`/`error`, `truncated`,
  and `limit_usage` keys.
  """
  @spec run_tool(String.t(), map(), keyword()) :: map()
  def run_tool(tool_name, args, opts \\ []) when is_binary(tool_name) and is_map(args) do
    module = Map.get(@known_tools, tool_name)

    if module do
      module.run(args, opts)
    else
      %{
        ok: false,
        error: %{
          code: "tool_unavailable",
          message: "Unknown tool: #{tool_name}",
          kind: "unavailable",
          retryable: false,
          details: %{}
        },
        truncated: false
      }
    end
  end
end
