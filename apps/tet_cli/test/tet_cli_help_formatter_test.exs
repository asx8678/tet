defmodule Tet.CLI.HelpFormatterTest do
  use ExUnit.Case, async: true

  alias Tet.CLI.HelpFormatter
  alias Tet.Docs.Topic

  describe "format_topic/1" do
    test "formats a topic with all sections" do
      topic = Topic.build(:cli)
      output = HelpFormatter.format_topic(topic)

      assert output =~ "## CLI Usage"
      assert output =~ topic.content
      assert output =~ "Related commands:"
      assert output =~ "tet help"
      assert output =~ "⚠  Safety warnings:"
      assert output =~ "Verification commands:"
    end

    test "formats a topic with safety warnings" do
      topic = Topic.build(:security)
      output = HelpFormatter.format_topic(topic)

      assert output =~ "⚠  Safety warnings:"
      assert output =~ "Security policies restrict agent capabilities"
    end

    test "formats release topic with recovery runbook" do
      topic = Topic.build(:release)
      output = HelpFormatter.format_topic(topic)

      assert output =~ "Release Recovery Runbook"
      assert output =~ "DETECT FAILED STATE"
      assert output =~ "SAFETY CHECKS BEFORE ROLLBACK"
      assert output =~ "RECOVERY COMMANDS"
      assert output =~ "POST-RECOVERY VERIFICATION"
    end
  end

  describe "format_command_list/0" do
    test "returns a formatted command list" do
      output = HelpFormatter.format_command_list()

      assert output =~ "Available TET commands:"
      assert is_binary(output)
    end
  end

  describe "format_search_results/1" do
    test "returns matching topics for a query" do
      output = HelpFormatter.format_search_results("CLI")

      assert output =~ "Search results for"
      assert output =~ "CLI Usage"
    end

    test "returns no results message for no match" do
      output = HelpFormatter.format_search_results("xyznonexistent12345")

      assert output =~ "No results found"
    end
  end
end
