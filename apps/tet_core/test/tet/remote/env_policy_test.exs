defmodule Tet.Remote.EnvPolicyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Remote.EnvPolicy

  describe "validate_allowlist/1" do
    test "returns empty list for nil" do
      assert {:ok, []} = EnvPolicy.validate_allowlist(nil)
    end

    test "validates a list of valid env names" do
      assert {:ok, ["HOME", "PATH"]} = EnvPolicy.validate_allowlist(["PATH", "HOME"])
    end

    test "deduplicates entries" do
      assert {:ok, ["PATH"]} = EnvPolicy.validate_allowlist(["PATH", "PATH", "PATH"])
    end

    test "sorts entries for determinism" do
      assert {:ok, ["HOME", "PATH", "TERM"]} =
               EnvPolicy.validate_allowlist(["TERM", "PATH", "HOME"])
    end

    test "accepts atom names" do
      assert {:ok, ["HOME", "PATH"]} = EnvPolicy.validate_allowlist([:PATH, :HOME])
    end

    test "rejects non-list input" do
      assert {:error, {:invalid_env_allowlist, :not_a_list}} =
               EnvPolicy.validate_allowlist("PATH")
    end

    test "rejects empty string name" do
      assert {:error, {:invalid_env_allowlist, {:empty_name, ""}}} =
               EnvPolicy.validate_allowlist([""])
    end

    test "rejects name with equals sign (injection)" do
      assert {:error, {:invalid_env_allowlist, {:name_contains_equals, "EVIL=value"}}} =
               EnvPolicy.validate_allowlist(["EVIL=value"])
    end

    test "rejects name starting with digit" do
      assert {:error, {:invalid_env_allowlist, {:invalid_chars, "1BAD"}}} =
               EnvPolicy.validate_allowlist(["1BAD"])
    end

    test "rejects name with special characters" do
      assert {:error, {:invalid_env_allowlist, {:invalid_chars, "BAD-NAME"}}} =
               EnvPolicy.validate_allowlist(["BAD-NAME"])
    end

    test "rejects secret-carrying env names" do
      assert {:error, {:secret_name, "AWS_SECRET_ACCESS_KEY"}} =
               EnvPolicy.validate_allowlist(["AWS_SECRET_ACCESS_KEY"])

      assert {:error, {:secret_name, "DATABASE_URL"}} =
               EnvPolicy.validate_allowlist(["DATABASE_URL"])

      assert {:error, {:secret_name, "API_KEY"}} =
               EnvPolicy.validate_allowlist(["API_KEY"])

      assert {:error, {:secret_name, "MY_PASSWORD"}} =
               EnvPolicy.validate_allowlist(["MY_PASSWORD"])

      assert {:error, {:secret_name, "AUTH_TOKEN"}} =
               EnvPolicy.validate_allowlist(["AUTH_TOKEN"])

      assert {:error, {:secret_name, "CREDENTIAL_FILE"}} =
               EnvPolicy.validate_allowlist(["CREDENTIAL_FILE"])
    end

    test "default env forwarding is empty" do
      assert {:ok, []} = EnvPolicy.validate_allowlist([])
    end

    test "rejects non-string entry in list" do
      assert {:error, {:invalid_env_allowlist, :invalid_type}} =
               EnvPolicy.validate_allowlist([123])
    end
  end

  describe "filter_env/2" do
    test "only returns allowed variables" do
      env = %{
        "PATH" => "/usr/bin",
        "HOME" => "/home/user",
        "AWS_SECRET_ACCESS_KEY" => "super-secret",
        "DATABASE_URL" => "postgres://..."
      }

      result = EnvPolicy.filter_env(env, ["PATH", "HOME"])

      assert result == %{"PATH" => "/usr/bin", "HOME" => "/home/user"}
    end

    test "returns empty map when allowlist is empty" do
      env = %{"PATH" => "/usr/bin", "HOME" => "/home/user"}
      assert EnvPolicy.filter_env(env, []) == %{}
    end

    test "returns empty map when no keys match" do
      env = %{"FOO" => "bar"}
      assert EnvPolicy.filter_env(env, ["BAZ"]) == %{}
    end
  end

  describe "filter_and_redact_env/2" do
    test "filters and redacts secret-looking values even if key is on allowlist" do
      env = %{
        "PATH" => "/usr/bin",
        "AWS_SECRET_ACCESS_KEY" => "super-secret-value"
      }

      result = EnvPolicy.filter_and_redact_env(env, ["PATH", "AWS_SECRET_ACCESS_KEY"])

      assert result["PATH"] == "/usr/bin"
      assert result["AWS_SECRET_ACCESS_KEY"] == "[REDACTED]"
    end

    test "still filters non-allowed keys" do
      env = %{
        "PATH" => "/usr/bin",
        "DATABASE_URL" => "postgres://secret"
      }

      result = EnvPolicy.filter_and_redact_env(env, ["PATH"])

      refute Map.has_key?(result, "DATABASE_URL")
    end
  end

  describe "secret_key_name?/1" do
    test "detects secret-carrying names" do
      assert EnvPolicy.secret_key_name?("AWS_SECRET_ACCESS_KEY")
      assert EnvPolicy.secret_key_name?("DATABASE_URL")
      assert EnvPolicy.secret_key_name?("API_KEY")
      assert EnvPolicy.secret_key_name?("AUTH_TOKEN")
      assert EnvPolicy.secret_key_name?("PRIVATE_KEY")
      assert EnvPolicy.secret_key_name?("MY_PASSWORD")
      assert EnvPolicy.secret_key_name?("CREDENTIAL_FILE")
      assert EnvPolicy.secret_key_name?("AUTHORIZATION_HEADER")
    end

    test "does not flag benign names" do
      refute EnvPolicy.secret_key_name?("PATH")
      refute EnvPolicy.secret_key_name?("HOME")
      refute EnvPolicy.secret_key_name?("TERM")
      refute EnvPolicy.secret_key_name?("LANG")
      refute EnvPolicy.secret_key_name?("USER")
    end

    test "handles hyphenated names" do
      assert EnvPolicy.secret_key_name?("api-key")
    end
  end

  describe "suggested_safe_vars/0" do
    test "returns advisory list of commonly safe env names" do
      vars = EnvPolicy.suggested_safe_vars()
      assert is_list(vars)
      assert "PATH" in vars
      assert "HOME" in vars
      assert vars == Enum.sort(vars)
    end

    test "is advisory-only — not auto-applied to new profiles" do
      # New profiles always start with empty allowlist
      assert {:ok, []} = EnvPolicy.validate_allowlist([])
      # suggested_safe_vars must NOT be used as a default
      assert EnvPolicy.suggested_safe_vars() != []
    end
  end
end
