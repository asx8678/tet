defmodule Tet.Remote.TrustBoundaryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Remote.TrustBoundary
  alias Tet.Remote.SSHProfile

  describe "trust_levels/0" do
    test "returns three levels in descending trust order" do
      assert TrustBoundary.trust_levels() == [:local, :trusted_remote, :untrusted_remote]
    end
  end

  describe "trust_ranking/1" do
    test "local is highest" do
      assert TrustBoundary.trust_ranking(:local) == 3
    end

    test "trusted_remote is middle" do
      assert TrustBoundary.trust_ranking(:trusted_remote) == 2
    end

    test "untrusted_remote is lowest" do
      assert TrustBoundary.trust_ranking(:untrusted_remote) == 1
    end
  end

  describe "trusts_at_least?/2" do
    test "local trusts everything" do
      assert TrustBoundary.trusts_at_least?(:local, :local)
      assert TrustBoundary.trusts_at_least?(:local, :trusted_remote)
      assert TrustBoundary.trusts_at_least?(:local, :untrusted_remote)
    end

    test "trusted_remote trusts trusted and untrusted" do
      assert TrustBoundary.trusts_at_least?(:trusted_remote, :trusted_remote)
      assert TrustBoundary.trusts_at_least?(:trusted_remote, :untrusted_remote)
      refute TrustBoundary.trusts_at_least?(:trusted_remote, :local)
    end

    test "untrusted_remote only trusts untrusted" do
      assert TrustBoundary.trusts_at_least?(:untrusted_remote, :untrusted_remote)
      refute TrustBoundary.trusts_at_least?(:untrusted_remote, :trusted_remote)
      refute TrustBoundary.trusts_at_least?(:untrusted_remote, :local)
    end

    test "trusts_at_least? fails closed for invalid levels" do
      refute TrustBoundary.trusts_at_least?(:trusted_remote, :sketchy)
      refute TrustBoundary.trusts_at_least?(:sketchy, :untrusted_remote)
    end
  end

  describe "valid_trust_level?/1" do
    test "returns true for known trust levels" do
      assert TrustBoundary.valid_trust_level?(:local)
      assert TrustBoundary.valid_trust_level?(:trusted_remote)
      assert TrustBoundary.valid_trust_level?(:untrusted_remote)
    end

    test "returns false for unknown trust levels" do
      refute TrustBoundary.valid_trust_level?(:sketchy)
      refute TrustBoundary.valid_trust_level?("local")
      refute TrustBoundary.valid_trust_level?(nil)
      refute TrustBoundary.valid_trust_level?(123)
    end
  end

  describe "operation gates" do
    test "untrusted_remote can check status" do
      assert :ok = TrustBoundary.check_operation(:untrusted_remote, :read_status)
      assert :ok = TrustBoundary.check_operation(:untrusted_remote, :check_version)
      assert :ok = TrustBoundary.check_operation(:untrusted_remote, :heartbeat_check)
    end

    test "untrusted_remote cannot execute commands" do
      assert {:error,
              {:trust_violation,
               %{
                 operation: :execute_commands,
                 required: :trusted_remote,
                 actual: :untrusted_remote
               }}} =
               TrustBoundary.check_operation(:untrusted_remote, :execute_commands)
    end

    test "trusted_remote can execute commands" do
      assert :ok = TrustBoundary.check_operation(:trusted_remote, :execute_commands)
      assert :ok = TrustBoundary.check_operation(:trusted_remote, :read_files)
      assert :ok = TrustBoundary.check_operation(:trusted_remote, :deploy_releases)
    end

    test "trusted_remote cannot install packages" do
      assert {:error,
              {:trust_violation,
               %{operation: :install_packages, required: :local, actual: :trusted_remote}}} =
               TrustBoundary.check_operation(:trusted_remote, :install_packages)
    end

    test "local can do everything" do
      assert :ok = TrustBoundary.check_operation(:local, :install_packages)
      assert :ok = TrustBoundary.check_operation(:local, :full_shell)
      assert :ok = TrustBoundary.check_operation(:local, :manage_services)
      assert :ok = TrustBoundary.check_operation(:local, :write_files)
    end

    test "unknown operation returns error" do
      assert {:error, {:unknown_operation, :teleport}} =
               TrustBoundary.check_operation(:local, :teleport)
    end

    test "invalid trust level fails closed for operations" do
      assert {:error, {:invalid_trust_level, :sketchy}} =
               TrustBoundary.check_operation(:sketchy, :read_status)

      assert {:error, {:invalid_trust_level, "local"}} =
               TrustBoundary.check_operation("local", :read_status)
    end
  end

  describe "minimum_trust_for/1" do
    test "read_status requires untrusted_remote" do
      assert {:ok, :untrusted_remote} = TrustBoundary.minimum_trust_for(:read_status)
    end

    test "execute_commands requires trusted_remote" do
      assert {:ok, :trusted_remote} = TrustBoundary.minimum_trust_for(:execute_commands)
    end

    test "install_packages requires local" do
      assert {:ok, :local} = TrustBoundary.minimum_trust_for(:install_packages)
    end

    test "unknown operation returns error" do
      assert {:error, :unknown_operation} = TrustBoundary.minimum_trust_for(:bogus)
    end
  end

  describe "check_secret_access/2" do
    test "untrusted_remote can never access secrets" do
      scope = %{ref: "secret://deploy/key", min_trust: :untrusted_remote}

      assert {:error, {:secret_access_denied, :untrusted_remote_no_secrets}} =
               TrustBoundary.check_secret_access(:untrusted_remote, scope)
    end

    test "trusted_remote can access trusted-level secrets" do
      scope = %{ref: "secret://deploy/key", min_trust: :trusted_remote}

      assert :ok = TrustBoundary.check_secret_access(:trusted_remote, scope)
    end

    test "trusted_remote cannot access local-only secrets" do
      scope = %{ref: "secret://root/ca", min_trust: :local}

      assert {:error, {:secret_access_denied, %{actual: :trusted_remote, required: :local}}} =
               TrustBoundary.check_secret_access(:trusted_remote, scope)
    end

    test "local can access everything" do
      scope = %{ref: "secret://root/ca", min_trust: :local}
      assert :ok = TrustBoundary.check_secret_access(:local, scope)

      scope2 = %{ref: "secret://deploy/key", min_trust: :trusted_remote}
      assert :ok = TrustBoundary.check_secret_access(:local, scope2)
    end

    test "rejects invalid scope" do
      assert {:error, {:secret_access_denied, :invalid_scope}} =
               TrustBoundary.check_secret_access(:local, "not a scope")
    end

    test "invalid trust level fails closed for secret access" do
      assert {:error, {:secret_access_denied, {:invalid_trust_level, :sketchy}}} =
               TrustBoundary.check_secret_access(:sketchy, %{ref: "s", min_trust: :local})

      assert {:error, {:secret_access_denied, {:invalid_trust_level, "local"}}} =
               TrustBoundary.check_secret_access("local", %{ref: "s", min_trust: :local})
    end

    test "invalid min_trust fails closed for secret access" do
      assert {:error, {:secret_access_denied, {:invalid_min_trust, :sketchy}}} =
               TrustBoundary.check_secret_access(:trusted_remote, %{
                 ref: "secret://deploy/key",
                 min_trust: :sketchy
               })
    end
  end

  describe "accessible_secrets/2" do
    test "filters to only accessible secrets for trusted_remote" do
      scopes = [
        %{ref: "secret://deploy/key", min_trust: :trusted_remote},
        %{ref: "secret://root/ca", min_trust: :local},
        %{ref: "secret://status/key", min_trust: :untrusted_remote}
      ]

      result = TrustBoundary.accessible_secrets(:trusted_remote, scopes)

      refs = Enum.map(result, & &1.ref)
      assert "secret://deploy/key" in refs
      assert "secret://status/key" in refs
      refute "secret://root/ca" in refs
    end

    test "returns nothing for untrusted_remote" do
      scopes = [
        %{ref: "secret://deploy/key", min_trust: :trusted_remote},
        %{ref: "secret://status/key", min_trust: :untrusted_remote}
      ]

      assert [] = TrustBoundary.accessible_secrets(:untrusted_remote, scopes)
    end

    test "returns everything for local" do
      scopes = [
        %{ref: "secret://deploy/key", min_trust: :trusted_remote},
        %{ref: "secret://root/ca", min_trust: :local}
      ]

      assert length(TrustBoundary.accessible_secrets(:local, scopes)) == 2
    end

    test "accessible_secrets drops scopes with invalid min_trust" do
      scopes = [
        %{ref: "secret://bad/key", min_trust: :sketchy},
        %{ref: "secret://deploy/key", min_trust: :trusted_remote}
      ]

      result = TrustBoundary.accessible_secrets(:trusted_remote, scopes)
      assert [%{ref: "secret://deploy/key"}] = result
    end
  end

  describe "from_profile/1" do
    test "derives trust level from SSH profile" do
      {:ok, profile} =
        SSHProfile.new(
          host: "deploy.example.com",
          user: "deploy",
          identity_file: "/home/deploy/.ssh/id_ed25519",
          host_key_fingerprint: "SHA256:uNiVztksCsDhcc0u9e8BgrJXVGD2YdhU9E9fVZ7g2Rg=",
          trust_level: :trusted_remote
        )

      assert TrustBoundary.from_profile(profile) == :trusted_remote
    end
  end

  describe "summarize/1" do
    test "summarizes local trust boundary" do
      summary = TrustBoundary.summarize(:local)

      assert summary.trust_level == :local
      assert summary.trust_ranking == 3
      assert :install_packages in summary.allowed_operations
      assert :read_status in summary.allowed_operations
      assert summary.secret_access == :all_secrets
    end

    test "summarizes trusted_remote trust boundary" do
      summary = TrustBoundary.summarize(:trusted_remote)

      assert summary.trust_level == :trusted_remote
      assert summary.trust_ranking == 2
      assert :execute_commands in summary.allowed_operations
      refute :install_packages in summary.allowed_operations
      assert summary.secret_access == :scoped_secrets_only
    end

    test "summarizes untrusted_remote trust boundary" do
      summary = TrustBoundary.summarize(:untrusted_remote)

      assert summary.trust_level == :untrusted_remote
      assert summary.trust_ranking == 1
      assert :read_status in summary.allowed_operations
      refute :execute_commands in summary.allowed_operations
      assert summary.secret_access == :no_secrets
    end
  end
end
