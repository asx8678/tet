defmodule Tet.Remote.PolicyParityGatesTest do
  @moduledoc """
  BD-0056: Policy parity gate tests — active task, category, trust boundary.

  Verifies that remote tools obey the same task/category/trust gates as
  local tools. Remote cannot bypass local gates.
  """

  use ExUnit.Case, async: true

  alias Tet.Remote.PolicyParity
  alias Tet.Remote.TrustBoundary
  alias Tet.ShellPolicy
  alias Tet.PlanMode.{Gate, Policy}
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
  # 1. Active task requirement
  # ===========================================================================

  describe "check_active_task/1 — remote cannot skip active task gate" do
    test "passes with valid task_id and task_category" do
      assert :ok =
               PolicyParity.check_active_task(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "blocks when task_id is nil — same as local gate" do
      assert {:error, {:parity_violation, {:no_active_task, %{task_id: nil}}}} =
               PolicyParity.check_active_task(%{
                 trust_level: :trusted_remote,
                 task_id: nil,
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "blocks when task_id is empty string — same as local gate" do
      assert {:error, {:parity_violation, {:no_active_task, %{task_id: ""}}}} =
               PolicyParity.check_active_task(%{
                 trust_level: :trusted_remote,
                 task_id: "",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "blocks when task_category is nil — same as local gate" do
      assert {:error, {:parity_violation, {:no_active_task, %{task_category: nil}}}} =
               PolicyParity.check_active_task(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: nil,
                 mode: :execute
               })
    end

    test "blocks when task_category is not an atom — same as local gate" do
      assert {:error, {:parity_violation, {:no_active_task, %{task_category: "acting"}}}} =
               PolicyParity.check_active_task(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: "acting",
                 mode: :execute
               })
    end

    test "blocks when both task_id and task_category are missing" do
      assert {:error, {:parity_violation, {:no_active_task, %{task_id: nil}}}} =
               PolicyParity.check_active_task(%{
                 trust_level: :trusted_remote,
                 task_id: nil,
                 task_category: nil,
                 mode: :execute
               })
    end

    test "trust level does not bypass the active task gate" do
      assert {:error, {:parity_violation, {:no_active_task, %{task_id: nil}}}} =
               PolicyParity.check_active_task(%{
                 trust_level: :local,
                 task_id: nil,
                 task_category: :acting,
                 mode: :execute
               })
    end
  end

  # ===========================================================================
  # 2. Category gates
  # ===========================================================================

  describe "check_category_gate/1 — remote tools respect category gates" do
    test "acting category allows shell contract execution" do
      assert :ok =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 contract: shell_contract()
               })
    end

    test "verifying category allows shell contract execution" do
      assert :ok =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :verifying,
                 mode: :execute,
                 contract: shell_contract()
               })
    end

    test "debugging category allows shell contract execution" do
      assert :ok =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :debugging,
                 mode: :execute,
                 contract: shell_contract()
               })
    end

    test "researching category blocks shell contract — same as local" do
      assert {:error, {:parity_violation, {:category_gate_blocked, :category_blocks_tool}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :execute,
                 contract: shell_contract()
               })
    end

    test "planning category blocks shell contract — same as local" do
      assert {:error, {:parity_violation, {:category_gate_blocked, :category_blocks_tool}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :planning,
                 mode: :execute,
                 contract: shell_contract()
               })
    end

    test "plan mode blocks mutating contract — same as local gate" do
      assert {:error, {:parity_violation, {:category_gate_blocked, :plan_mode_blocks_mutation}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :plan,
                 contract: mutating_contract()
               })
    end

    test "plan mode allows read-only contract — same as local gate" do
      assert :ok =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :plan,
                 contract: local_read_contract()
               })
    end

    test "without contract, acting category passes via ShellPolicy fallback" do
      assert :ok =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "without contract, researching category fails — same as local" do
      assert {:error, {:parity_violation, {:category_gate_blocked, :no_acting_category}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :execute
               })
    end
  end

  describe "check_category_gate/1 — no-contract command respects mode gating" do
    test "command without contract and mode: :plan is blocked (regression)" do
      # Previously, command + no contract + mode: :plan would pass
      # because only ShellPolicy.acting_category? was checked.
      # Now, shell_contract is used so Gate.evaluate handles mode gating.
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :plan,
                 command: ["mix", "test"]
               })
    end

    test "command without contract and mode: :execute with acting category passes" do
      assert :ok =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["mix", "test"]
               })
    end

    test "command without contract and mode: :plan with researching category blocked" do
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :plan,
                 command: ["git", "status"]
               })
    end
  end

  # ===========================================================================
  # 3. Trust boundary restrictions
  # ===========================================================================

  describe "check_trust_boundary/1 — trust levels restrict operations" do
    test "untrusted remote cannot execute commands" do
      assert {:error, {:parity_violation, {:trust_boundary_denied, _}}} =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["mix", "test"]
               })
    end

    test "untrusted remote can only read status" do
      assert :ok =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute
               })
    end

    test "trusted remote can execute commands" do
      assert :ok =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["mix", "test"]
               })
    end

    test "trusted remote cannot install packages — same as local restriction" do
      assert {:error,
              {:trust_violation,
               %{operation: :install_packages, required: :local, actual: :trusted_remote}}} =
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

    test "local trust can do everything" do
      assert :ok =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :local,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["mix", "test"]
               })
    end

    test "trust boundary error preserves violation details" do
      assert {:error,
              {:parity_violation,
               {:trust_boundary_denied,
                {:trust_violation,
                 %{
                   operation: :execute_commands,
                   required: :trusted_remote,
                   actual: :untrusted_remote
                 }}}}} =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["mix", "test"]
               })
    end
  end

  describe "check_trust_boundary/1 — explicit :operation field" do
    test "explicit :operation field is used directly for trust boundary check" do
      assert {:error, {:parity_violation, {:trust_boundary_denied, _}}} =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :install_packages
               })
    end

    test "explicit :operation :install_packages passes for :local trust" do
      assert :ok =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :local,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :install_packages
               })
    end

    test "explicit :operation overrides inferred operation" do
      # Without :operation, a command-free context would infer :read_status
      # which passes for :untrusted_remote. With :operation, we check directly.
      assert {:error, {:parity_violation, {:trust_boundary_denied, _}}} =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :execute_commands
               })
    end

    test "explicit :operation with read_status passes for untrusted" do
      assert :ok =
               PolicyParity.check_trust_boundary(%{
                 trust_level: :untrusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :read_status
               })
    end
  end

  # ===========================================================================
  # Cross-cutting: category + trust never widen local permissions
  # ===========================================================================

  describe "check_category_gate/1 — shell command cannot bypass gate with read-only contract (BD-0056 #1)" do
    test "command + read-only contract + mode: :plan is BLOCKED" do
      # A remote caller cannot bypass shell policy by attaching a read-only
      # contract to a shell command. The command always forces shell contract.
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :plan,
                 command: ["mix", "test"],
                 contract: local_read_contract()
               })
    end

    test "command + read-only contract + mode: :execute + acting category passes" do
      # With :execute mode and :acting category, shell contract passes Gate.evaluate.
      assert :ok =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 command: ["mix", "test"],
                 contract: local_read_contract()
               })
    end

    test "command + read-only contract + researching category is BLOCKED" do
      # Shell contract requires acting categories — researching is not one.
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :execute,
                 command: ["git", "status"],
                 contract: local_read_contract()
               })
    end
  end

  describe "check_category_gate/1 — mutating operation without contract is blocked in plan mode (BD-0056 #3)" do
    test "operation: :write_scoped_files + mode: :plan is BLOCKED" do
      # Mutating operations without a contract use a synthetic mutating contract
      # so Gate.evaluate handles mode gating. Plan mode blocks mutation.
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :plan,
                 operation: :write_scoped_files
               })
    end

    test "operation: :write_scoped_files + mode: :execute + acting passes" do
      assert :ok =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :write_scoped_files
               })
    end

    test "operation: :install_packages + mode: :plan is BLOCKED" do
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :plan,
                 operation: :install_packages
               })
    end

    test "non-mutating operation + mode: :plan falls back to category check" do
      # read_files is not a mutating operation, so no synthetic contract is used.
      # It falls back to the category check.
      assert {:error, {:parity_violation, {:category_gate_blocked, :no_acting_category}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :plan,
                 operation: :read_files
               })
    end
  end

  describe "check_category_gate/1 — mutating operation + read-only contract bypass (BD-0056 #4)" do
    test "operation: :write_scoped_files + read-only contract + mode: :plan → BLOCKED" do
      # A mutating operation MUST force shell_contract even when a read-only
      # contract is attached. Previously, match?(%Contract{}, contract) ran
      # before mutating_operation?(operation), letting the read-only contract
      # bypass mode gating.
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :plan,
                 operation: :write_scoped_files,
                 contract: local_read_contract()
               })
    end

    test "operation: :write_scoped_files + read-only contract + category: :researching → BLOCKED" do
      # Shell contract requires acting categories — researching is not one.
      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :researching,
                 mode: :execute,
                 operation: :write_scoped_files,
                 contract: local_read_contract()
               })
    end

    test "operation: :write_scoped_files + read-only contract + mode: :execute + acting → passes" do
      # Legitimate use: mutating operation with execute mode and acting category.
      assert :ok =
               PolicyParity.check_category_gate(%{
                 trust_level: :trusted_remote,
                 task_id: "t-001",
                 task_category: :acting,
                 mode: :execute,
                 operation: :write_scoped_files,
                 contract: local_read_contract()
               })
    end
  end

  describe "cross-cutting: remote cannot widen local category permissions" do
    test "local gate blocks researching + mutating — remote also blocks" do
      contract = mutating_contract()
      context = %{mode: :plan, task_category: :researching, task_id: "t-001"}
      policy = Policy.default()

      assert {:block, _} = Gate.evaluate(contract, policy, context)

      assert {:error, {:parity_violation, {:category_gate_blocked, _}}} =
               PolicyParity.check_category_gate(
                 Map.merge(context, %{
                   trust_level: :trusted_remote,
                   contract: contract
                 })
               )
    end
  end
end
