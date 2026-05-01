defmodule Tet.ShellPolicyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.ShellPolicy

  describe "default_allowlist/0" do
    test "returns a list of allowlist entries" do
      allowlist = ShellPolicy.default_allowlist()
      assert is_list(allowlist)
      assert length(allowlist) > 0

      Enum.each(allowlist, fn entry ->
        assert Map.has_key?(entry, :command)
        assert Map.has_key?(entry, :subcommands)
        assert Map.has_key?(entry, :risk)
        assert is_binary(entry.command)
        assert is_list(entry.subcommands)
        assert entry.risk in [:read, :low, :medium, :high]
      end)
    end

    test "includes git and mix commands" do
      allowlist = ShellPolicy.default_allowlist()
      commands = Enum.map(allowlist, & &1.command)
      assert "git" in commands
      assert "mix" in commands
    end

    test "git status is read risk" do
      allowlist = ShellPolicy.default_allowlist()
      git_read = Enum.filter(allowlist, &(&1.command == "git" and &1.risk == :read))
      assert length(git_read) > 0
      read_subcommands = Enum.flat_map(git_read, & &1.subcommands)
      assert "status" in read_subcommands
      assert "log" in read_subcommands
      assert "diff" in read_subcommands
    end

    test "mix test is medium risk" do
      allowlist = ShellPolicy.default_allowlist()
      mix_medium = Enum.filter(allowlist, &(&1.command == "mix" and &1.risk == :medium))
      assert length(mix_medium) > 0
      medium_subcommands = Enum.flat_map(mix_medium, & &1.subcommands)
      assert "test" in medium_subcommands
      assert "compile" in medium_subcommands
    end
  end

  describe "check_command/2" do
    test "allows git status as read risk" do
      assert {:ok, :read} = ShellPolicy.check_command(["git", "status"])
    end

    test "allows git diff as read risk" do
      assert {:ok, :read} = ShellPolicy.check_command(["git", "diff"])
    end

    test "allows mix test as medium risk" do
      assert {:ok, :medium} = ShellPolicy.check_command(["mix", "test"])
    end

    test "allows git commit as high risk" do
      assert {:ok, :high} = ShellPolicy.check_command(["git", "commit"])
    end

    test "allows git push as high risk" do
      assert {:ok, :high} = ShellPolicy.check_command(["git", "push", "--force"])
    end

    test "allows mix format as low risk" do
      assert {:ok, :low} = ShellPolicy.check_command(["mix", "format"])
    end

    test "blocks unknown executables" do
      assert {:error, {:blocked_command, :unknown_executable}} =
               ShellPolicy.check_command(["rm", "-rf", "/"])
    end

    test "blocks unknown git subcommands" do
      assert {:error, {:blocked_command, :subcommand_not_allowed}} =
               ShellPolicy.check_command(["git", "bisect"])
    end

    test "blocks empty command vector" do
      assert {:error, {:blocked_command, :empty_vector}} =
               ShellPolicy.check_command([])
    end

    test "allows mix test with path argument" do
      assert {:ok, :medium} = ShellPolicy.check_command(["mix", "test", "apps/tet_core/test/tet/shell_policy_test.exs"])
    end

    test "allows git status with verbose flag" do
      assert {:ok, :read} = ShellPolicy.check_command(["git", "status", "-v"])
    end

    test "allows mix deps.get" do
      assert {:ok, :medium} = ShellPolicy.check_command(["mix", "deps.get"])
    end

    test "allows mix deps.compile" do
      assert {:ok, :medium} = ShellPolicy.check_command(["mix", "deps.compile"])
    end

    test "allows git add as low risk" do
      assert {:ok, :low} = ShellPolicy.check_command(["git", "add", "lib/foo.ex"])
    end

    test "allows git init as medium risk" do
      assert {:ok, :medium} = ShellPolicy.check_command(["git", "init"])
    end

    test "blocks command with empty executable" do
      assert {:error, {:blocked_command, :unknown_executable}} =
               ShellPolicy.check_command([""])
    end

    test "respects custom allowlist" do
      custom = [%{command: "echo", subcommands: [], risk: :low}]
      assert {:ok, :low} = ShellPolicy.check_command(["echo", "hello"], custom)
      assert {:error, {:blocked_command, :unknown_executable}} =
               ShellPolicy.check_command(["git", "status"], custom)
    end
  end

  describe "allowed?/2" do
    test "returns true for allowed commands" do
      assert ShellPolicy.allowed?(["git", "status"])
      assert ShellPolicy.allowed?(["mix", "test"])
    end

    test "returns false for blocked commands" do
      refute ShellPolicy.allowed?(["rm", "-rf", "/"])
      refute ShellPolicy.allowed?(["git", "bisect"])
    end
  end

  describe "shell_contract/0" do
    test "returns a contract with shell-appropriate metadata" do
      contract = ShellPolicy.shell_contract()
      assert contract.name == "shell-policy"
      assert contract.read_only == false
      assert contract.mutation == :execute
      assert contract.modes == [:execute]
      assert contract.task_categories == [:acting, :verifying, :debugging]
      assert contract.execution.executes_code == true
      assert contract.execution.mutates_workspace == true
      assert :executes_shell_command in contract.execution.effects
      assert :run_test in contract.execution.effects
    end
  end

  describe "acting_category?/1" do
    test "returns true for acting categories" do
      assert ShellPolicy.acting_category?(:acting)
      assert ShellPolicy.acting_category?(:verifying)
      assert ShellPolicy.acting_category?(:debugging)
    end

    test "returns false for non-acting categories" do
      refute ShellPolicy.acting_category?(:researching)
      refute ShellPolicy.acting_category?(:planning)
      refute ShellPolicy.acting_category?(:documenting)
    end

    test "returns false for nil" do
      refute ShellPolicy.acting_category?(nil)
    end
  end

  describe "risk_levels/0" do
    test "returns all four risk levels" do
      assert ShellPolicy.risk_levels() == [:read, :low, :medium, :high]
    end
  end

  describe "acting_categories/0" do
    test "returns acting/verifying/debugging" do
      assert ShellPolicy.acting_categories() == [:acting, :verifying, :debugging]
    end
  end
end
