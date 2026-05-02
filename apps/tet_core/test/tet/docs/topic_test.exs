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
      assert "tet config validate" in topic.related_commands
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
end
