defmodule Tet.ShellPolicy.ArtifactTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.ShellPolicy.Artifact

  describe "new/1" do
    test "builds a valid artifact from required attrs" do
      attrs = %{
        command: ["mix", "test"],
        risk: :medium,
        exit_code: 0,
        stdout: "All tests passed",
        stderr: "",
        cwd: "/workspace",
        duration_ms: 1_234,
        tool_call_id: "call_abc123"
      }

      assert {:ok, artifact} = Artifact.new(attrs)
      assert artifact.command == ["mix", "test"]
      assert artifact.risk == :medium
      assert artifact.exit_code == 0
      assert artifact.stdout == "All tests passed"
      assert artifact.stderr == ""
      assert artifact.cwd == "/workspace"
      assert artifact.duration_ms == 1_234
      assert artifact.tool_call_id == "call_abc123"
      assert artifact.successful == true
    end

    test "marks artifact as unsuccessful on non-zero exit code" do
      attrs = %{
        command: ["mix", "test"],
        risk: :medium,
        exit_code: 1,
        stdout: "",
        stderr: "failures",
        cwd: "/workspace",
        duration_ms: 500,
        tool_call_id: "call_abc"
      }

      assert {:ok, artifact} = Artifact.new(attrs)
      refute artifact.successful
    end

    test "accepts optional task_id" do
      attrs = %{
        command: ["git", "status"],
        risk: :read,
        exit_code: 0,
        stdout: "clean",
        stderr: "",
        cwd: "/workspace",
        duration_ms: 100,
        tool_call_id: "call_xyz",
        task_id: "t1"
      }

      assert {:ok, artifact} = Artifact.new(attrs)
      assert artifact.task_id == "t1"
    end

    test "accepts optional metadata" do
      attrs = %{
        command: ["mix", "test"],
        risk: :medium,
        exit_code: 0,
        stdout: "",
        stderr: "",
        cwd: "/workspace",
        duration_ms: 100,
        tool_call_id: "call_123",
        metadata: %{test_count: 42, failures: 0}
      }

      assert {:ok, artifact} = Artifact.new(attrs)
      assert artifact.metadata == %{test_count: 42, failures: 0}
    end

    test "rejects invalid command" do
      attrs = %{
        command: "not a list",
        risk: :medium,
        exit_code: 0,
        stdout: "",
        stderr: "",
        cwd: "/workspace",
        duration_ms: 100,
        tool_call_id: "call_123"
      }

      assert {:error, _reason} = Artifact.new(attrs)
    end

    test "rejects invalid risk" do
      attrs = %{
        command: ["mix", "test"],
        risk: :extreme,
        exit_code: 0,
        stdout: "",
        stderr: "",
        cwd: "/workspace",
        duration_ms: 100,
        tool_call_id: "call_123"
      }

      assert {:error, _reason} = Artifact.new(attrs)
    end

    test "rejects negative exit code" do
      attrs = %{
        command: ["mix", "test"],
        risk: :medium,
        exit_code: -1,
        stdout: "",
        stderr: "",
        cwd: "/workspace",
        duration_ms: 100,
        tool_call_id: "call_123"
      }

      assert {:error, _reason} = Artifact.new(attrs)
    end

    test "accepts string risk via String.to_existing_atom" do
      attrs = %{
        command: ["git", "status"],
        risk: "read",
        exit_code: 0,
        stdout: "",
        stderr: "",
        cwd: "/workspace",
        duration_ms: 50,
        tool_call_id: "call_abc"
      }

      assert {:ok, artifact} = Artifact.new(attrs)
      assert artifact.risk == :read
    end
  end

  describe "new!/1" do
    test "builds or raises" do
      attrs = %{
        command: ["echo", "hi"],
        risk: :low,
        exit_code: 0,
        stdout: "hi",
        stderr: "",
        cwd: "/tmp",
        duration_ms: 10,
        tool_call_id: "call_1"
      }

      assert %Artifact{} = Artifact.new!(attrs)
    end

    test "raises on invalid attrs" do
      assert_raise ArgumentError, fn ->
        Artifact.new!(%{command: "bad"})
      end
    end
  end

  describe "to_map/1" do
    test "converts to JSON-friendly map" do
      attrs = %{
        command: ["mix", "test"],
        risk: :medium,
        exit_code: 0,
        stdout: "ok",
        stderr: "",
        cwd: "/workspace",
        duration_ms: 500,
        tool_call_id: "call_1",
        task_id: "t1"
      }

      {:ok, artifact} = Artifact.new(attrs)
      map = Artifact.to_map(artifact)

      assert map.command == ["mix", "test"]
      assert map.risk == "medium"
      assert map.exit_code == 0
      assert map.stdout == "ok"
      assert map.successful == true
      assert map.task_id == "t1"
    end
  end
end
