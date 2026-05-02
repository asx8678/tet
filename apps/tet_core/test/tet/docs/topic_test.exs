defmodule Tet.Docs.TopicTest do
  use ExUnit.Case, async: true

  alias Tet.Docs.Topic

  describe "topics/0" do
    test "returns all 10 topic atoms" do
      assert Topic.topics() == [
               :cli,
               :config,
               :profiles,
               :tools,
               :mcp,
               :remote,
               :repair,
               :security,
               :migration,
               :release
             ]
    end
  end

  describe "build_all/0" do
    test "builds all topics" do
      topics = Topic.build_all()
      assert length(topics) == 10
    end

    test "each topic has the expected fields" do
      for topic <- Topic.build_all() do
        assert is_atom(topic.id)
        assert is_binary(topic.title) and topic.title != ""
        assert is_binary(topic.content) and topic.content != ""
        assert is_list(topic.related_commands)
        assert is_list(topic.safety_warnings)
        assert is_list(topic.verification_commands)
      end
    end

    test "each topic has a non-empty title" do
      for topic <- Topic.build_all() do
        assert topic.title != ""
      end
    end
  end

  describe "build/1" do
    test "builds :cli topic correctly" do
      topic = Topic.build(:cli)
      assert topic.id == :cli
      assert topic.title == "CLI Usage"
      assert "tet help" in topic.related_commands
    end

    test "builds :config topic correctly" do
      topic = Topic.build(:config)
      assert topic.id == :config
      assert topic.title == "Configuration"
      assert "tet doctor" in topic.related_commands
    end

    test "builds :profiles topic correctly" do
      topic = Topic.build(:profiles)
      assert topic.id == :profiles
      assert topic.title == "Profiles"
    end

    test "builds :tools topic correctly" do
      topic = Topic.build(:tools)
      assert topic.id == :tools
      assert topic.title == "Tools & Contracts"
    end

    test "builds :mcp topic correctly" do
      topic = Topic.build(:mcp)
      assert topic.id == :mcp
      assert topic.title == "Model Context Protocol (MCP)"
    end

    test "builds :remote topic correctly" do
      topic = Topic.build(:remote)
      assert topic.id == :remote
      assert topic.title == "Remote Operations"
    end

    test "builds :repair topic correctly" do
      topic = Topic.build(:repair)
      assert topic.id == :repair
      assert topic.title == "Self-Healing & Repair"
    end

    test "builds :security topic correctly" do
      topic = Topic.build(:security)
      assert topic.id == :security
      assert topic.title == "Security Policy"
    end

    test "builds :migration topic correctly" do
      topic = Topic.build(:migration)
      assert topic.id == :migration
      assert topic.title == "Migration"
    end

    test "builds :release topic correctly" do
      topic = Topic.build(:release)
      assert topic.id == :release
      assert topic.title == "Release Management"
    end
  end

  describe "string_to_id/0" do
    test "returns a map of all topic strings to atoms" do
      map = Topic.string_to_id()
      assert map["cli"] == :cli
      assert map["config"] == :config
      assert map["profiles"] == :profiles
      assert map["release"] == :release
      assert map_size(map) == 10
    end
  end

  describe "lookup/1" do
    test "returns {:ok, id} for valid string" do
      assert {:ok, :cli} = Topic.lookup("cli")
      assert {:ok, :security} = Topic.lookup("security")
    end

    test "returns :error for unknown string" do
      assert Topic.lookup("nonexistent") == :error
    end

    test "is case-sensitive" do
      assert Topic.lookup("CLI") == :error
    end
  end

  describe "safety warnings and verification commands" do
    test "every topic has at least one safety warning" do
      topics = Topic.build_all()

      for topic <- topics do
        assert topic.safety_warnings != [],
               "Topic #{topic.id} has no safety warnings — every topic must have at least one"
      end
    end

    test "every topic has at least one verification command" do
      topics = Topic.build_all()

      for topic <- topics do
        assert topic.verification_commands != [],
               "Topic #{topic.id} has no verification commands — every topic must have at least one"
      end
    end

    test "each safety warning is a non-empty string" do
      topics = Topic.build_all()

      for topic <- topics do
        Enum.each(topic.safety_warnings, fn warning ->
          assert is_binary(warning) and String.length(warning) > 0
        end)
      end
    end

    test "each verification command is a non-empty string" do
      topics = Topic.build_all()

      for topic <- topics do
        Enum.each(topic.verification_commands, fn cmd ->
          assert is_binary(cmd) and String.length(cmd) > 0
        end)
      end
    end
  end
end
