defmodule Tet.DocsTest do
  use ExUnit.Case, async: true

  alias Tet.Docs

  describe "topics/0" do
    test "returns 10 topics" do
      assert length(Docs.topics()) == 10
    end

    test "all topics have the correct structure" do
      for topic <- Docs.topics() do
        assert is_atom(topic.id)
        assert is_binary(topic.title)
        assert is_binary(topic.content)
        assert is_list(topic.related_commands)
        assert is_list(topic.safety_warnings)
        assert is_list(topic.verification_commands)
      end
    end
  end

  describe "get/1" do
    test "returns {:ok, topic} for valid topic" do
      assert {:ok, topic} = Docs.get(:cli)
      assert topic.id == :cli
    end

    test "returns :error for invalid topic" do
      assert Docs.get(:nonexistent) == :error
    end
  end

  describe "search/1" do
    test "finds topics by title keyword" do
      results = Docs.search("CLI")
      assert length(results) >= 1
      assert Enum.any?(results, &(&1.id == :cli))
    end

    test "finds topics by content keyword" do
      results = Docs.search("profile")
      assert length(results) >= 1
      assert Enum.any?(results, &(&1.id == :profiles))
    end

    test "is case-insensitive" do
      results_upper = Docs.search("SECURITY")
      results_lower = Docs.search("security")
      assert length(results_upper) == length(results_lower)
    end

    test "returns empty list for no match" do
      assert Docs.search("xyznonexistent12345") == []
    end
  end

  describe "commands/0" do
    test "returns a sorted list of unique commands" do
      cmds = Docs.commands()
      assert is_list(cmds)
      assert Enum.all?(cmds, &is_binary/1)
      assert cmds == Enum.sort(cmds)

      # Check for duplicates
      assert length(cmds) == length(Enum.uniq(cmds))
    end

    test "includes common commands" do
      cmds = Docs.commands()
      assert "tet help" in cmds
    end
  end

  describe "safety_warnings/0" do
    test "returns a list of safety warnings" do
      warnings = Docs.safety_warnings()
      assert is_list(warnings)
      assert Enum.all?(warnings, &is_binary/1)
      assert length(warnings) > 0
    end

    test "no duplicate warnings" do
      warnings = Docs.safety_warnings()
      assert length(warnings) == length(Enum.uniq(warnings))
    end

    test "warnings include actionable safety guidance" do
      warnings = Docs.safety_warnings()

      for warning <- warnings do
        assert String.length(warning) > 10
      end
    end
  end

  describe "verification_commands/0" do
    test "returns a sorted list of verification commands" do
      cmds = Docs.verification_commands()
      assert is_list(cmds)
      assert Enum.all?(cmds, &is_binary/1)
      assert cmds == Enum.sort(cmds)
    end

    test "contains at least one command" do
      assert length(Docs.verification_commands()) > 0
    end
  end
end
