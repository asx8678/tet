defmodule Tet.Secrets.PatternRegistryTest do
  use ExUnit.Case, async: true

  alias Tet.Secrets.PatternRegistry

  describe "builtin_patterns/0" do
    test "returns a non-empty list of patterns" do
      patterns = PatternRegistry.builtin_patterns()
      assert is_list(patterns)
      assert length(patterns) > 0
    end

    test "each pattern is a {name, regex, classification} tuple" do
      for {name, regex, classification} <- PatternRegistry.builtin_patterns() do
        assert is_atom(name)
        assert is_struct(regex, Regex)
        assert is_atom(classification)
      end
    end
  end

  describe "pattern_names/0" do
    test "returns atom names of all patterns" do
      names = PatternRegistry.pattern_names()
      assert :openai_api_key in names
      assert :openai_project_key in names
      assert :anthropic_api_key in names
      assert :aws_access_key in names
      assert :bearer_token in names
      assert :private_key_block in names
    end
  end

  describe "merge/1" do
    test "adds custom patterns" do
      custom = [{:my_custom_key, ~r/CUSTOM-[A-Z]+/, :api_key}]
      merged = PatternRegistry.merge(custom)

      assert Enum.any?(merged, fn {name, _, _} -> name == :my_custom_key end)
      # Built-ins still present
      assert Enum.any?(merged, fn {name, _, _} -> name == :openai_api_key end)
    end

    test "custom patterns override built-ins with same name" do
      custom_regex = ~r/OVERRIDE-[A-Z]+/
      custom = [{:openai_api_key, custom_regex, :token}]
      merged = PatternRegistry.merge(custom)

      openai_entries = Enum.filter(merged, fn {name, _, _} -> name == :openai_api_key end)
      assert length(openai_entries) == 1

      [{_name, regex, classification}] = openai_entries
      assert regex == custom_regex
      assert classification == :token
    end

    test "merging empty list returns built-ins unchanged" do
      merged = PatternRegistry.merge([])
      builtin = PatternRegistry.builtin_patterns()
      assert length(merged) == length(builtin)

      merged_names = Enum.map(merged, fn {name, _, _} -> name end)
      builtin_names = Enum.map(builtin, fn {name, _, _} -> name end)
      assert merged_names == builtin_names
    end
  end

  describe "match/1" do
    test "matches OpenAI API keys" do
      assert {:openai_api_key, :api_key} =
               PatternRegistry.match("my key is sk-abcdefghijklmnopqrstuvwx")
    end

    test "matches Anthropic API keys" do
      assert {:anthropic_api_key, :api_key} =
               PatternRegistry.match("key: sk-ant-api03-abcdefghijklmnopqrstu")
    end

    test "matches AWS access keys" do
      assert {:aws_access_key, :api_key} =
               PatternRegistry.match("aws key AKIAIOSFODNN7EXAMPLE")
    end

    test "matches Bearer tokens" do
      assert {:bearer_token, :token} =
               PatternRegistry.match("Authorization: Bearer eyJhbGciOiJSUzI1Ni")
    end

    test "matches connection strings" do
      assert {:connection_string, :connection_string} =
               PatternRegistry.match("DATABASE_URL=postgres://user:pass@localhost/db")
    end

    test "matches private key blocks" do
      assert {:private_key_block, :private_key} =
               PatternRegistry.match("-----BEGIN RSA PRIVATE KEY-----")
    end

    test "matches GitHub tokens" do
      assert {:github_token, :token} =
               PatternRegistry.match("token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij")
    end

    test "returns nil for clean strings" do
      assert nil == PatternRegistry.match("just a normal string with no secrets")
    end
  end

  describe "match/2 with custom patterns" do
    test "uses custom patterns" do
      custom = [{:custom_key, ~r/MYAPP-[A-Z0-9]{10,}/, :api_key}]

      assert {:custom_key, :api_key} =
               PatternRegistry.match("key: MYAPP-ABCDEF1234", custom)

      assert nil == PatternRegistry.match("sk-proj-abcdefghijklmnopqrstu", custom)
    end
  end

  describe "BD-0068 regression: short sk- keys" do
    test "matches sk-proj- style OpenAI project keys" do
      assert {:openai_project_key, :api_key} =
               PatternRegistry.match("key: sk-proj-abc123def456")
    end

    test "matches short sk-ant- Anthropic keys" do
      assert {:anthropic_api_key, :api_key} =
               PatternRegistry.match("key: sk-ant-api03-shortkey")
    end

    test "matches short sk- OpenAI keys" do
      assert {:openai_api_key, :api_key} =
               PatternRegistry.match("key: sk-abcdef123456")
    end

    test "sk-proj- keys are classified before generic sk- pattern" do
      # Ordering matters: specific patterns first
      assert {:openai_project_key, :api_key} =
               PatternRegistry.match("sk-proj-abc123def456")
    end

    test "sk-ant- keys are classified before generic sk- pattern" do
      assert {:anthropic_api_key, :api_key} =
               PatternRegistry.match("sk-ant-api03-shortkey")
    end
  end

  describe "match_all/1" do
    test "returns all matching patterns" do
      # A string with an Anthropic key also matches OpenAI pattern
      value = "sk-ant-abcdefghijklmnopqrstuvwx"
      matches = PatternRegistry.match_all(value)
      assert length(matches) >= 1

      classifications = Enum.map(matches, fn {_name, class} -> class end)
      assert :api_key in classifications
    end

    test "returns empty list for clean strings" do
      assert [] == PatternRegistry.match_all("hello world nothing here")
    end
  end
end
