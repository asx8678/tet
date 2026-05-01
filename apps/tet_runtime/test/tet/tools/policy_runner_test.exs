defmodule Tet.Runtime.Tools.PolicyRunnerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Runtime.Tools.PolicyRunner
  alias Tet.ShellPolicy.Artifact

  @workspace_root File.cwd!()

  describe "validate/2" do
    test "passes for allowed git command within sandbox with acting task" do
      assert :ok =
               PolicyRunner.validate(["git", "status"],
                 cwd: @workspace_root,
                 workspace_root: @workspace_root,
                 task_id: "t1",
                 task_category: :acting,
                 mode: :execute
               )
    end

    test "passes for allowed mix command within sandbox with verifying task" do
      assert :ok =
               PolicyRunner.validate(["mix", "format", "--check-formatted"],
                 cwd: @workspace_root,
                 workspace_root: @workspace_root,
                 task_id: "t2",
                 task_category: :verifying,
                 mode: :execute
               )
    end

    test "blocks unknown command" do
      assert {:error, denial} =
               PolicyRunner.validate(["rm", "-rf", "/"],
                 cwd: @workspace_root,
                 workspace_root: @workspace_root,
                 task_id: "t1",
                 task_category: :acting
               )

      assert denial.code == "policy_denial"
      assert denial.kind == "policy_denial"
    end

    test "blocks sandbox escape" do
      assert {:error, denial} =
               PolicyRunner.validate(["git", "status"],
                 cwd: "/outside",
                 workspace_root: @workspace_root,
                 task_id: "t1",
                 task_category: :acting
               )

      assert denial.code == "workspace_escape"
    end

    test "blocks when no cwd specified" do
      assert {:error, denial} =
               PolicyRunner.validate(["git", "status"],
                 workspace_root: @workspace_root,
                 task_id: "t1",
                 task_category: :acting
               )

      assert denial.code == "workspace_escape"
    end

    test "blocks when no workspace_root specified" do
      assert {:error, denial} =
               PolicyRunner.validate(["git", "status"],
                 cwd: @workspace_root,
                 task_id: "t1",
                 task_category: :acting
               )

      assert denial.code == "workspace_escape"
    end

    test "blocks when gate rejects (plan mode, no task)" do
      assert {:error, denial} =
               PolicyRunner.validate(["git", "status"],
                 cwd: @workspace_root,
                 workspace_root: @workspace_root,
                 mode: :plan
               )

      assert denial.code == "policy_denial"
    end

    test "blocks when gate rejects (plan mode, researching task)" do
      assert {:error, denial} =
               PolicyRunner.validate(["git", "status"],
                 cwd: @workspace_root,
                 workspace_root: @workspace_root,
                 task_id: "t1",
                 task_category: :researching,
                 mode: :plan
               )

      assert denial.code == "policy_denial"
    end
  end

  describe "run/2" do
    test "executes git status successfully" do
      assert {:ok, %Artifact{} = artifact} =
               PolicyRunner.run(["git", "status"],
                 cwd: @workspace_root,
                 workspace_root: @workspace_root,
                 task_id: "t1",
                 task_category: :acting,
                 tool_call_id: "call_1",
                 mode: :execute
               )

      assert artifact.risk == :read
      assert artifact.exit_code == 0
      assert is_binary(artifact.stdout)
      assert artifact.tool_call_id == "call_1"
      assert artifact.task_id == "t1"
      assert artifact.cwd == @workspace_root
      assert artifact.duration_ms > 0
      assert artifact.successful == true
    end

    test "executes git log with short flag" do
      assert {:ok, %Artifact{} = artifact} =
               PolicyRunner.run(["git", "log", "--oneline", "-1"],
                 cwd: @workspace_root,
                 workspace_root: @workspace_root,
                 task_id: "t1",
                 task_category: :acting,
                 tool_call_id: "call_2",
                 mode: :execute
               )

      assert artifact.risk == :read
      assert artifact.exit_code == 0
      assert artifact.tool_call_id == "call_2"
    end

    test "executes mix format --check-formatted just runs without blocking" do
      assert {:ok, %Artifact{} = artifact} =
               PolicyRunner.run(["mix", "format", "--check-formatted"],
                 cwd: @workspace_root,
                 workspace_root: @workspace_root,
                 task_id: "t1",
                 task_category: :acting,
                 tool_call_id: "call_3",
                 mode: :execute
               )

      assert artifact.risk == :low
      # exit_code may be 0 or 1 depending on formatting;
      # we just check it executed without policy denial
      assert is_integer(artifact.exit_code)
      assert artifact.tool_call_id == "call_3"
    end

    test "blocks unknown command with error denial" do
      assert {:error, denial} =
               PolicyRunner.run(["nonexistent-command"],
                 cwd: @workspace_root,
                 workspace_root: @workspace_root,
                 task_id: "t1",
                 task_category: :acting,
                 tool_call_id: "call_4"
               )

      assert denial.code == "policy_denial"
    end

    test "blocks subcommand not in allowlist" do
      assert {:error, denial} =
               PolicyRunner.run(["git", "bisect"],
                 cwd: @workspace_root,
                 workspace_root: @workspace_root,
                 task_id: "t1",
                 task_category: :acting,
                 tool_call_id: "call_5"
               )

      assert denial.code == "policy_denial"
    end
  end
end
