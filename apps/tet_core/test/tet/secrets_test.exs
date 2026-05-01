defmodule Tet.SecretsTest do
  use ExUnit.Case, async: true

  alias Tet.Secrets

  describe "register_pattern/3" do
    test "adds a custom pattern to the registry" do
      patterns = Secrets.register_pattern(:my_token, ~r/MYTOKEN-[A-Z]+/)
      assert Enum.any?(patterns, fn {name, _, _} -> name == :my_token end)
    end

    test "defaults classification to :token" do
      patterns = Secrets.register_pattern(:my_thing, ~r/THING-[A-Z]+/)
      {_name, _regex, classification} = Enum.find(patterns, fn {n, _, _} -> n == :my_thing end)
      assert classification == :token
    end

    test "accepts custom classification" do
      patterns = Secrets.register_pattern(:my_pass, ~r/PASS-[A-Z]+/, :password)
      {_name, _regex, classification} = Enum.find(patterns, fn {n, _, _} -> n == :my_pass end)
      assert classification == :password
    end
  end

  describe "known_patterns/0" do
    test "returns built-in patterns" do
      patterns = Secrets.known_patterns()
      assert is_list(patterns)
      assert length(patterns) > 0
      names = Enum.map(patterns, fn {name, _, _} -> name end)
      assert :openai_api_key in names
    end
  end

  describe "contains_secret?/1" do
    test "detects OpenAI API key" do
      assert Secrets.contains_secret?("my key is sk-proj-abcdefghijklmnopqrstu")
    end

    test "detects Anthropic API key" do
      assert Secrets.contains_secret?("key sk-ant-api03-abcdefghijklmnopqrstu")
    end

    test "detects Bearer token" do
      assert Secrets.contains_secret?("Authorization: Bearer eyJhbGciOiJSUzI1Ni")
    end

    test "detects connection strings" do
      assert Secrets.contains_secret?("postgres://user:pass@localhost:5432/mydb")
    end

    test "detects private key blocks" do
      assert Secrets.contains_secret?("-----BEGIN RSA PRIVATE KEY-----")
    end

    test "returns false for clean strings" do
      refute Secrets.contains_secret?("hello world")
      refute Secrets.contains_secret?("just some normal text")
      refute Secrets.contains_secret?("config = %{name: \"test\"}")
    end

    test "accepts custom patterns via opts" do
      custom = [{:custom, ~r/ZZZZ-[A-Z]{10,}/, :token}]
      assert Secrets.contains_secret?("key ZZZZ-ABCDEFGHIJ", patterns: custom)
      refute Secrets.contains_secret?("sk-proj-abcdefghijklmnopqrstu", patterns: custom)
    end
  end

  describe "classify/1" do
    test "classifies OpenAI key as api_key" do
      assert {:secret, :api_key} = Secrets.classify("sk-proj-abcdefghijklmnopqrstu")
    end

    test "classifies Anthropic key as api_key" do
      assert {:secret, :api_key} = Secrets.classify("sk-ant-api03-abcdefghijklmnopqrstu")
    end

    test "classifies Bearer token as token" do
      assert {:secret, :token} =
               Secrets.classify("Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9")
    end

    test "classifies connection string" do
      assert {:secret, :connection_string} =
               Secrets.classify("postgres://user:pass@localhost/db")
    end

    test "classifies private key" do
      assert {:secret, :private_key} =
               Secrets.classify("-----BEGIN RSA PRIVATE KEY-----")
    end

    test "returns :clean for non-secret strings" do
      assert :clean = Secrets.classify("hello world")
      assert :clean = Secrets.classify("some normal config value")
    end
  end

  describe "fingerprint/1" do
    test "returns stable fingerprints" do
      value = "sk-secret123456789012345"
      fp1 = Secrets.fingerprint(value)
      fp2 = Secrets.fingerprint(value)
      assert fp1 == fp2
    end

    test "different values produce different fingerprints" do
      fp1 = Secrets.fingerprint("secret-one")
      fp2 = Secrets.fingerprint("secret-two")
      assert fp1 != fp2
    end

    test "fingerprint starts with fp: prefix" do
      fp = Secrets.fingerprint("anything")
      assert String.starts_with?(fp, "fp:")
    end

    test "fingerprint is a fixed length" do
      fp = Secrets.fingerprint("some-secret-value")
      # "fp:" + 12 hex chars = 15 chars total
      assert String.length(fp) == 15
    end
  end

  describe "partial_preview/1" do
    test "shows prefix and suffix for long values" do
      preview = Secrets.partial_preview("sk-abcdefghijklmnopqrstuvwxyz")
      assert preview == "sk-a...wxyz"
    end

    test "fully redacts short values" do
      preview = Secrets.partial_preview("short")
      assert preview == "[REDACTED]"
    end

    test "respects min_length threshold" do
      # 12 chars is the default minimum
      preview = Secrets.partial_preview("123456789012")
      assert preview == "1234...9012"

      preview = Secrets.partial_preview("12345678901")
      assert preview == "[REDACTED]"
    end

    test "respects custom prefix/suffix lengths" do
      preview =
        Secrets.partial_preview("sk-abcdefghijklmnopqrstuvwxyz", prefix_len: 6, suffix_len: 3)

      assert preview == "sk-abc...xyz"
    end
  end
end
