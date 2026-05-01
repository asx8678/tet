defmodule Tet.Remote.SSHProfileTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Remote.SSHProfile

  # A real-length SHA256 fingerprint for tests that just need a valid one
  @valid_fp "SHA256:uNiVztksCsDhcc0u9e8BgrJXVGD2YdhU9E9fVZ7g2Rg="
  @valid_id "/home/u/.ssh/id_ed25519"

  describe "new/1" do
    test "builds a valid SSH profile from a keyword list" do
      attrs = [
        host: "deploy.example.com",
        port: 2222,
        user: "deploy",
        identity_file: "/home/deploy/.ssh/id_ed25519",
        host_key_fingerprint: @valid_fp,
        remote_root: "/opt/tet",
        trust_level: :trusted_remote,
        env_allowlist: ["PATH", "HOME"]
      ]

      assert {:ok, profile} = SSHProfile.new(attrs)
      assert profile.host == "deploy.example.com"
      assert profile.port == 2222
      assert profile.user == "deploy"
      assert profile.identity_file == "/home/deploy/.ssh/id_ed25519"
      assert profile.host_key_fingerprint == "sha256:uNiVztksCsDhcc0u9e8BgrJXVGD2YdhU9E9fVZ7g2Rg="
      assert profile.remote_root == "/opt/tet"
      assert profile.trust_level == :trusted_remote
      assert profile.env_allowlist == ["HOME", "PATH"]
    end

    test "builds a valid SSH profile from a map" do
      attrs = %{
        "host" => "staging.example.com",
        "user" => "ci",
        "identity_file" => @valid_id,
        "host_key_fingerprint" => @valid_fp,
        "trust_level" => :trusted_remote
      }

      assert {:ok, profile} = SSHProfile.new(attrs)
      assert profile.host == "staging.example.com"
      assert profile.port == 22
      assert profile.user == "ci"
    end

    test "uses default port 22 when port is nil" do
      attrs = [
        host: "host.example.com",
        user: "root",
        identity_file: @valid_id,
        host_key_fingerprint: @valid_fp,
        trust_level: :untrusted_remote
      ]

      assert {:ok, profile} = SSHProfile.new(attrs)
      assert profile.port == 22
    end

    test "parses string port to integer" do
      attrs = [
        host: "host.example.com",
        port: "2222",
        user: "root",
        identity_file: @valid_id,
        host_key_fingerprint: @valid_fp,
        trust_level: :untrusted_remote
      ]

      assert {:ok, profile} = SSHProfile.new(attrs)
      assert profile.port == 2222
    end
  end

  describe "new/1 validation - host" do
    test "rejects nil host" do
      assert {:error, {:invalid_ssh_profile, :host_required}} =
               SSHProfile.new(host: nil, user: "root", trust_level: :local)
    end

    test "rejects empty host" do
      assert {:error, {:invalid_ssh_profile, :host_required}} =
               SSHProfile.new(host: "", user: "root", trust_level: :local)
    end

    test "rejects host with whitespace" do
      assert {:error, {:invalid_ssh_profile, {:host_invalid_chars, "bad host"}}} =
               SSHProfile.new(host: "bad host", user: "root", trust_level: :local)
    end

    test "rejects host with control characters" do
      assert {:error, {:invalid_ssh_profile, {:host_invalid_chars, "host\tname"}}} =
               SSHProfile.new(host: "host\tname", user: "root", trust_level: :local)

      assert {:error, {:invalid_ssh_profile, {:host_invalid_chars, "host\nname"}}} =
               SSHProfile.new(host: "host\nname", user: "root", trust_level: :local)
    end

    test "rejects host with shell metacharacters" do
      for bad_host <- ["host;rm", "host|pipe", "host&bg", "host$dollar", "host`backtick"] do
        assert {:error, {:invalid_ssh_profile, {:host_invalid_chars, ^bad_host}}} =
                 SSHProfile.new(host: bad_host, user: "root", trust_level: :local)
      end
    end

    test "accepts valid hostnames and IPs" do
      for good_host <- ["deploy.example.com", "192.168.1.1", "my-host", "host01"] do
        assert {:ok, _} = SSHProfile.new(host: good_host, user: "root", trust_level: :local)
      end
    end

    test "rejects host over 253 chars" do
      long_host = String.duplicate("a", 254)

      assert {:error, {:invalid_ssh_profile, {:host_too_long, ^long_host}}} =
               SSHProfile.new(host: long_host, user: "root", trust_level: :local)
    end

    test "accepts atom host" do
      assert {:ok, profile} =
               SSHProfile.new(
                 host: :localhost,
                 user: "root",
                 identity_file: @valid_id,
                 host_key_fingerprint: @valid_fp,
                 trust_level: :trusted_remote
               )

      assert profile.host == "localhost"
    end
  end

  describe "new/1 validation - port" do
    test "rejects port 0" do
      assert {:error, {:invalid_ssh_profile, {:port_out_of_range, 0}}} =
               SSHProfile.new(host: "h", user: "u", port: 0, trust_level: :local)
    end

    test "rejects negative port" do
      assert {:error, {:invalid_ssh_profile, {:port_out_of_range, -1}}} =
               SSHProfile.new(host: "h", user: "u", port: -1, trust_level: :local)
    end

    test "rejects port > 65535" do
      assert {:error, {:invalid_ssh_profile, {:port_out_of_range, 70000}}} =
               SSHProfile.new(host: "h", user: "u", port: 70000, trust_level: :local)
    end

    test "rejects non-numeric string port" do
      assert {:error, {:invalid_ssh_profile, {:port_out_of_range, "abc"}}} =
               SSHProfile.new(host: "h", user: "u", port: "abc", trust_level: :local)
    end
  end

  describe "new/1 validation - user" do
    test "rejects nil user" do
      assert {:error, {:invalid_ssh_profile, :user_required}} =
               SSHProfile.new(host: "h", user: nil, trust_level: :local)
    end

    test "rejects empty user" do
      assert {:error, {:invalid_ssh_profile, :user_required}} =
               SSHProfile.new(host: "h", user: "", trust_level: :local)
    end

    test "rejects user with whitespace" do
      assert {:error, {:invalid_ssh_profile, {:user_invalid_chars, "bad user"}}} =
               SSHProfile.new(host: "h", user: "bad user", trust_level: :local)
    end

    test "rejects user with control characters" do
      assert {:error, {:invalid_ssh_profile, {:user_invalid_chars, "user\tname"}}} =
               SSHProfile.new(host: "h", user: "user\tname", trust_level: :local)

      assert {:error, {:invalid_ssh_profile, {:user_invalid_chars, "user\nname"}}} =
               SSHProfile.new(host: "h", user: "user\nname", trust_level: :local)
    end

    test "rejects user with shell metacharacters" do
      for bad_user <- ["user;rm", "user|pipe", "user&bg", "user$dollar", "user`tick"] do
        assert {:error, {:invalid_ssh_profile, {:user_invalid_chars, ^bad_user}}} =
                 SSHProfile.new(host: "h", user: bad_user, trust_level: :local)
      end
    end

    test "accepts valid usernames" do
      for good_user <- ["deploy", "_system", "my-user", "user_01", "service$"] do
        assert {:ok, _} = SSHProfile.new(host: "h", user: good_user, trust_level: :local)
      end
    end
  end

  describe "new/1 validation - identity_file" do
    test "local trust accepts nil identity_file" do
      assert {:ok, _} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 identity_file: nil,
                 trust_level: :local
               )
    end

    test "trusted_remote requires identity_file" do
      assert {:error, {:invalid_ssh_profile, :identity_file_required_for_remote}} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 identity_file: nil,
                 host_key_fingerprint: "SHA256:uNiVztksCsDhcc0u9e8BgrJXVGD2YdhU9E9fVZ7g2Rg=",
                 trust_level: :trusted_remote
               )
    end

    test "untrusted_remote requires identity_file" do
      assert {:error, {:invalid_ssh_profile, :identity_file_required_for_remote}} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 identity_file: nil,
                 host_key_fingerprint: "SHA256:uNiVztksCsDhcc0u9e8BgrJXVGD2YdhU9E9fVZ7g2Rg=",
                 trust_level: :untrusted_remote
               )
    end

    test "accepts absolute path" do
      assert {:ok, profile} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 identity_file: "/home/user/.ssh/id_ed25519",
                 host_key_fingerprint: @valid_fp,
                 trust_level: :trusted_remote
               )

      assert profile.identity_file == "/home/user/.ssh/id_ed25519"
    end

    test "accepts tilde-expanded path" do
      assert {:ok, profile} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 identity_file: "~/.ssh/id_ed25519",
                 host_key_fingerprint: @valid_fp,
                 trust_level: :trusted_remote
               )

      assert profile.identity_file == "~/.ssh/id_ed25519"
    end

    test "rejects relative path" do
      assert {:error, {:invalid_ssh_profile, {:identity_file_not_absolute, "id_rsa"}}} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 identity_file: "id_rsa",
                 host_key_fingerprint: @valid_fp,
                 trust_level: :trusted_remote
               )
    end
  end

  describe "new/1 validation - host_key_fingerprint" do
    test "accepts SHA256 fingerprint" do
      assert {:ok, profile} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 identity_file: "/home/u/.ssh/id_ed25519",
                 host_key_fingerprint: "SHA256:uNiVztksCsDhcc0u9e8BgrJXVGD2YdhU9E9fVZ7g2Rg=",
                 trust_level: :trusted_remote
               )

      assert profile.host_key_fingerprint == "sha256:uNiVztksCsDhcc0u9e8BgrJXVGD2YdhU9E9fVZ7g2Rg="
    end

    test "rejects MD5 fingerprint as insecure" do
      assert {:error, {:invalid_ssh_profile, {:md5_fingerprint_insecure, _}}} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 host_key_fingerprint: "1a:2b:3c:4d:5e:6f:7a:8b:9c:0d:1e:2f:3a:4b:5c:6d",
                 trust_level: :trusted_remote
               )
    end

    test "rejects trivially short SHA256 fingerprint" do
      assert {:error, {:invalid_ssh_profile, {:host_key_fingerprint_format, "SHA256:a"}}} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 host_key_fingerprint: "SHA256:a",
                 trust_level: :trusted_remote
               )

      assert {:error, {:invalid_ssh_profile, {:host_key_fingerprint_format, "SHA256:abc=="}}} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 host_key_fingerprint: "SHA256:abc==",
                 trust_level: :trusted_remote
               )
    end

    test "rejects invalid fingerprint format" do
      assert {:error, {:invalid_ssh_profile, {:host_key_fingerprint_format, "not-a-fingerprint"}}} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 host_key_fingerprint: "not-a-fingerprint",
                 trust_level: :trusted_remote
               )
    end
  end

  describe "new/1 validation - trust_level" do
    test "rejects nil trust_level" do
      assert {:error, {:invalid_ssh_profile, :trust_level_required}} =
               SSHProfile.new(host: "h", user: "u", trust_level: nil)
    end

    test "rejects unknown trust level" do
      assert {:error, {:invalid_ssh_profile, {:unknown_trust_level, :sketchy}}} =
               SSHProfile.new(host: "h", user: "u", trust_level: :sketchy)
    end

    test "accepts string trust level with hyphens" do
      assert {:ok, profile} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 identity_file: @valid_id,
                 host_key_fingerprint: @valid_fp,
                 trust_level: "trusted-remote"
               )

      assert profile.trust_level == :trusted_remote
    end
  end

  describe "new/1 validation - fingerprint required for remote" do
    test "local trust allows nil fingerprint" do
      assert {:ok, _} =
               SSHProfile.new(host: "h", user: "u", trust_level: :local)
    end

    test "trusted_remote requires fingerprint" do
      assert {:error, {:invalid_ssh_profile, :host_key_fingerprint_required_for_remote}} =
               SSHProfile.new(host: "h", user: "u", trust_level: :trusted_remote)
    end

    test "untrusted_remote requires fingerprint" do
      assert {:error, {:invalid_ssh_profile, :host_key_fingerprint_required_for_remote}} =
               SSHProfile.new(host: "h", user: "u", trust_level: :untrusted_remote)
    end
  end

  describe "new/1 validation - remote_root" do
    test "accepts absolute remote_root" do
      assert {:ok, profile} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 identity_file: @valid_id,
                 remote_root: "/opt/app",
                 host_key_fingerprint: @valid_fp,
                 trust_level: :trusted_remote
               )

      assert profile.remote_root == "/opt/app"
    end

    test "rejects relative remote_root" do
      assert {:error, {:invalid_ssh_profile, {:remote_root_not_absolute, "opt/app"}}} =
               SSHProfile.new(
                 host: "h",
                 user: "u",
                 identity_file: @valid_id,
                 remote_root: "opt/app",
                 host_key_fingerprint: @valid_fp,
                 trust_level: :trusted_remote
               )
    end
  end

  describe "verify_host_key/2" do
    setup do
      attrs = [
        host: "deploy.example.com",
        user: "deploy",
        identity_file: @valid_id,
        host_key_fingerprint: @valid_fp,
        trust_level: :trusted_remote
      ]

      {:ok, profile: SSHProfile.new!(attrs)}
    end

    test "returns :ok when fingerprints match", %{profile: profile} do
      assert :ok ==
               SSHProfile.verify_host_key(
                 profile,
                 "SHA256:uNiVztksCsDhcc0u9e8BgrJXVGD2YdhU9E9fVZ7g2Rg="
               )
    end

    test "returns :ok when fingerprints match with different casing", %{profile: profile} do
      assert :ok ==
               SSHProfile.verify_host_key(
                 profile,
                 "sha256:uNiVztksCsDhcc0u9e8BgrJXVGD2YdhU9E9fVZ7g2Rg="
               )
    end

    test "returns error when fingerprints differ", %{profile: profile} do
      assert {:error, {:host_key_mismatch, _}} =
               SSHProfile.verify_host_key(
                 profile,
                 "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
               )
    end

    test "returns error when profile has no pinned fingerprint" do
      profile = %SSHProfile{
        host: "h",
        port: 22,
        user: "u",
        host_key_fingerprint: nil,
        trust_level: :local
      }

      assert {:error, :no_pinned_host_key} =
               SSHProfile.verify_host_key(profile, "SHA256:abc==")
    end
  end

  describe "valid_fingerprint_format?/1" do
    test "accepts SHA256 format" do
      assert SSHProfile.valid_fingerprint_format?(
               "SHA256:uNiVztksCsDhcc0u9e8BgrJXVGD2YdhU9E9fVZ7g2Rg="
             )
    end

    test "accepts MD5 format" do
      assert SSHProfile.valid_fingerprint_format?(
               "1a:2b:3c:4d:5e:6f:7a:8b:9c:0d:1e:2f:3a:4b:5c:6d"
             )
    end

    test "rejects garbage" do
      refute SSHProfile.valid_fingerprint_format?("not-a-fingerprint")
    end

    test "rejects empty string" do
      refute SSHProfile.valid_fingerprint_format?("")
    end

    test "rejects MD5 with wrong number of parts" do
      refute SSHProfile.valid_fingerprint_format?("1a:2b:3c")
    end

    test "rejects MD5 with non-hex parts" do
      refute SSHProfile.valid_fingerprint_format?(
               "zz:2b:3c:4d:5e:6f:7a:8b:9c:0d:1e:2f:3a:4b:5c:6d"
             )
    end
  end

  describe "normalize_fingerprint/1" do
    test "lowercases, strips whitespace, and removes internal spaces" do
      assert "sha256:abc123" ==
               SSHProfile.normalize_fingerprint(" SHA256 : abc 123 ")
    end
  end

  describe "to_safe_map/1" do
    test "redacts identity_file and fingerprint" do
      {:ok, profile} =
        SSHProfile.new(
          host: "deploy.example.com",
          user: "deploy",
          identity_file: "/home/deploy/.ssh/id_ed25519",
          host_key_fingerprint: @valid_fp,
          trust_level: :trusted_remote
        )

      safe = SSHProfile.to_safe_map(profile)

      assert safe.host == "deploy.example.com"
      assert safe.user == "deploy"
      assert safe.identity_file == "[REDACTED]"
      assert safe.host_key_fingerprint == "[REDACTED]"
      assert safe.trust_level == :trusted_remote
    end
  end

  describe "from_config/1" do
    test "returns error when profile not found" do
      # Ensure no config set
      original = Application.get_env(:tet_core, :ssh_profiles)
      Application.put_env(:tet_core, :ssh_profiles, %{})

      assert {:error, {:ssh_profile_not_found, "nonexistent"}} =
               SSHProfile.from_config("nonexistent")

      # Restore
      if original,
        do: Application.put_env(:tet_core, :ssh_profiles, original),
        else: Application.delete_env(:tet_core, :ssh_profiles)
    end

    test "reads profile from app config" do
      original = Application.get_env(:tet_core, :ssh_profiles)

      Application.put_env(:tet_core, :ssh_profiles, %{
        "staging" => %{
          host: "staging.example.com",
          user: "deploy",
          identity_file: "/home/deploy/.ssh/id_ed25519",
          host_key_fingerprint: @valid_fp,
          trust_level: :trusted_remote
        }
      })

      assert {:ok, profile} = SSHProfile.from_config("staging")
      assert profile.host == "staging.example.com"

      # Restore
      if original,
        do: Application.put_env(:tet_core, :ssh_profiles, original),
        else: Application.delete_env(:tet_core, :ssh_profiles)
    end
  end
end
