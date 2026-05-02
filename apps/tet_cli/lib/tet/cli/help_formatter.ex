defmodule Tet.CLI.HelpFormatter do
  @moduledoc """
  CLI help text formatting — BD-0073.

  Formats topics, command lists, and search results for display in the
  terminal.
  """

  alias Tet.Docs
  alias Tet.Docs.Topic

  @doc """
  Formats a single topic for CLI display.

  Returns a string containing the topic title, content, related commands,
  safety warnings, and verification commands.
  """
  @spec format_topic(Topic.t()) :: String.t()
  def format_topic(%Topic{} = topic) do
    lines = [
      "## #{topic.title}",
      "",
      topic.content,
      ""
    ]

    lines =
      if topic.related_commands != [] do
        lines ++ ["Related commands:"] ++ Enum.map(topic.related_commands, &"  #{&1}") ++ [""]
      else
        lines
      end

    lines =
      if topic.safety_warnings != [] do
        lines ++ ["⚠  Safety warnings:"] ++ Enum.map(topic.safety_warnings, &"  ⚠  #{&1}") ++ [""]
      else
        lines
      end

    lines =
      if topic.verification_commands != [] do
        lines ++ ["Verification commands:"] ++ Enum.map(topic.verification_commands, &"  #{&1}")
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  @doc """
  Formats the full command list for CLI display.
  """
  @spec format_command_list() :: String.t()
  def format_command_list do
    commands = Docs.commands()

    lines = [
      "Available TET commands:",
      ""
    ]

    lines =
      lines ++ Enum.map(commands, &"  #{&1}")

    Enum.join(lines, "\n")
  end

  @doc """
  Formats search results for CLI display.

  Returns a string listing matching topics with their titles and a brief
  content excerpt.
  """
  @spec format_search_results(String.t()) :: String.t()
  def format_search_results(query) when is_binary(query) do
    results = Docs.search(query)

    if results == [] do
      "No results found for \"#{query}\"."
    else
      lines = ["Search results for \"#{query}\":", ""]

      lines =
        lines ++
          Enum.flat_map(results, fn topic ->
            excerpt = String.slice(topic.content, 0, 120)
            ["  #{topic.title}", "    #{excerpt}...", ""]
          end)

      Enum.join(lines, "\n")
    end
  end
end
