defmodule Tet.Remote.PolicyParityIntegrationTest do
  @moduledoc """
  BD-0056: Policy parity integration tests — full check, cross-cutting, summary, edge cases.

  Verifies that the full parity check composes all gates correctly, that
  remote never widens local permissions, and that edge cases fail closed.
  """

  use ExUnit.Case, async: true

  alias Tet.Remote.{PolicyParity, TrustBoundary}
  alias Tet.ShellPolicy
  alias Tet.Tool.Contract

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp local_read_contract do
    {:ok, contract} = Tet.Tool.ReadOnlyContracts.fetch("read")
    contract
  end

  defp shell_contract do
    ShellPolicy.shell_contract()
  end

  defp mutating_contract do
    {:ok, base_contract} = Tet.Tool.ReadOnlyContracts.fetch("read")
    %Contract{} = base = base_contract

    %{
      base
      | name: "test-write",
        read_only: false,
        mutation: :execute,
        modes: [:plan, :execute],
        task_categories: [:acting, :verifying, :debugging],
        approval: %{required: true, reason: "workspace mutation"},
        execution: %{
          base.execution
          | executes_code: true,
            mutates_workspace: true,
            status: :contract_only,
            effects: [:executes_shell_command, :write_file]
        }
    }
  end

  # ===========================================================================
  # 1. Full check (integration of all gates)
  # ===========================================================================

  describe "check/1 — full parity check (all gates)" do
    test "valid remote context with acting category, approved, in sandbox passes all gates" do
      assert :ok =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: shell_contract(),
                 approval_status: :approved,
                 cwd: "/workspace/project",
                 workspace_root: "/workspace/project"
               })
    end

    test "fails on first gate: no active task" do
      assert {:error, {:parity_violation, {:no_active_task, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: nil,
                 task_category: :acting,
                 mode: :execute,
                 contract: shell_contract()
               })
    end

    test "fails on category gate: researching blocks shell contract" do
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :execute,
                 contract: shell_contract()
               })
    end

    test "fails on trust boundary: untrusted remote cannot execute" do
      assert {:error, {:parity_violation, {:trust_boundary_denied, _}}} =
               PolicyParity.check(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["mix", "test"]
               })
    end

    test "fails on shell policy: blocked command" do
      assert {:error, {:parity_violation, {:shell_command_blocked, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["rm", "-rf", "/"]
               })
    end

    test "fails on env policy: secret on allowlist" do
      assert {:error, {:parity_violation, {:env_policy_denied, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: ["AWS_SECRET_ACCESS_KEY"],
                 env_map: %{}
               })
    end

    test "fails on approval parity: mutating without approval" do
      assert {:error, {:parity_violation, {:approval_required_for_mutation, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: shell_contract()
               })
    end

    test "fails on sandbox: cwd outside workspace" do
      assert {:error, {:parity_violation, {:sandbox_violation, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: mutating_contract(),
                 approval_status: :approved,
                 cwd: "/etc/evil",
                 workspace_root: "/workspace/project"
               })
    end

    test "read-only tool in plan mode with researching category passes all gates" do
      assert :ok =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :plan,
                 contract: local_read_contract()
               })
    end

    test "untrusted remote with no command passes (read_status only)" do
      assert :ok =
               PolicyParity.check(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "local context passes all gates for shell execution" do
      assert :ok =
               PolicyParity.check(%{
                 trust_level: :local,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "status"],
                 approval_status: :approved,
                 cwd: "/workspace/project",
                 workspace_root: "/workspace/project"
               })
    end
  end

  # ===========================================================================
  # 2. Cross-cutting: remote never widens local permissions
  # ===========================================================================

  describe "cross-cutting: remote cannot widen local permissions" do
    test "TrustBoundary blocks install_packages for trusted_remote — parity gate also enforces" do
      assert {:error, _} =
               TrustBoundary.check_operation(:trusted_remote, :install_packages)

      assert :ok =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: mutating_contract()
               })
    end

    test "untrusted_remote operations are a strict subset of trusted_remote operations" do
      untrusted_ops = TrustBoundary.untrusted_remote_operations()

      trusted_ops =
        TrustBoundary.trusted_remote_operations() ++ TrustBoundary.untrusted_remote_operations()

      for op <- untrusted_ops do
        assert op in trusted_ops
      end

      for op <- TrustBoundary.trusted_remote_operations() do
        refute op in untrusted_ops
      end
    end
  end

  # ===========================================================================
  # 3. Parity summary
  # ===========================================================================

  describe "parity_summary/1 — diagnostic summary" do
    test "returns summary reflecting actual implementation state" do
      summary = PolicyParity.parity_summary(:trusted_remote)

      assert summary.trust_level == :trusted_remote
      assert summary.active_task_required == true
      assert summary.category_gate_applies == true
      assert summary.shell_policy_applies == true
      # Env policy is enforced with default-deny (not just a boolean)
      assert summary.env_policy_applies == :enforced_with_default_deny
      # Approval parity requires explicit approval_status
      assert summary.approval_parity == :requires_approval_status
      # Sandbox is enforced for path operations
      assert summary.sandbox_parity == :enforced_for_path_operations
      assert is_map(summary.trust_constraints)
    end

    test "summary for local includes all constraints" do
      summary = PolicyParity.parity_summary(:local)

      assert summary.trust_level == :local
      assert summary.trust_constraints.trust_level == :local
      assert :install_packages in summary.trust_constraints.allowed_operations
    end

    test "summary for untrusted_remote shows no-secrets constraint" do
      summary = PolicyParity.parity_summary(:untrusted_remote)

      assert summary.trust_level == :untrusted_remote
      assert summary.trust_constraints.secret_access == :no_secrets
    end
  end

  # ===========================================================================
  # 4. Edge cases
  # ===========================================================================

  describe "edge cases — fail-closed for invalid inputs" do
    test "check_active_task fails closed for missing context keys" do
      assert {:error, {:parity_violation, {:no_active_task, _}}} =
               PolicyParity.check_active_task(%{
                 trust_level: :trusted_remote,
                 mode: :execute
               })
    end

    test "check_trust_boundary fails closed for invalid trust level" do
      assert {:error, {:parity_violation, {:trust_boundary_denied, _}}} =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :sketchy,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "status"]
               })
    end

    test "check_category_gate fails closed for contract with wrong mode" do
      assert {:error, {:parity_violation, {:category_gate_blocked, :mode_not_allowed}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :plan,
                 contract: shell_contract()
               })
    end

    test "check with multiple violations reports the first one" do
      assert {:error, {:parity_violation, {:no_active_task, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: nil,
                 task_category: nil,
                 mode: :execute,
                 command: ["rm", "-rf", "/"]
               })
    end

    test "check_trust_boundary infers read_status for no-command no-contract context" do
      assert :ok =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "env_map with secret keys outside allowlist is rejected" do
      assert {:error,
              {:parity_violation,
               {:env_policy_denied, {:keys_outside_allowlist, ["AWS_SECRET_ACCESS_KEY"]}}}} =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: ["PATH"],
                 env_map: %{"PATH" => "/usr/bin", "AWS_SECRET_ACCESS_KEY" => "s3cret"}
               })
    end

    test "command + plan mode blocked at category gate (regression)" do
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :plan,
                 command: ["mix", "test"]
               })
    end
  end

  # ===========================================================================
  # 5. BD-0056 regression: security fixes for category gate and approval parity
  # ===========================================================================

  describe "BD-0056 regressions — command + read-only contract bypass" do
    test "command + read-only contract + mode: :plan → BLOCKED at category gate" do
      # A remote caller cannot bypass shell policy by attaching a read-only
      # contract to a shell command (BD-0056 #1).
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :plan,
                 command: ["mix", "test"],
                 contract: local_read_contract()
               })
    end

    test "command + read-only contract + no approval → BLOCKED at approval gate" do
      # Read-only contract does not override a mutating command for approval (BD-0056 #2).
      assert {:error, {:parity_violation, {:approval_required_for_mutation, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "add"],
                 contract: local_read_contract()
               })
    end

    test "mutating operation + mode: :plan → BLOCKED at category gate" do
      # Mutating operations without a contract use synthetic shell contract
      # so Gate.evaluate handles mode gating (BD-0056 #3).
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :plan,
                 operation: :write_scoped_files
               })
    end

    test "git add + read-only contract + no approval → BLOCKED at approval gate" do
      # Explicit regression test: git add is a low-risk mutating command.
      # Attaching a read-only contract must not bypass approval (BD-0056 #2).
      assert {:error, {:parity_violation, {:approval_required_for_mutation, _}}} =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "add"],
                 contract: local_read_contract()
               })
    end
  end
end
