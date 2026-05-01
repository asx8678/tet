defmodule Tet.Runtime.Tools.PathGateAuditTest do
  @moduledoc """
  BD-0030: Path gate audit tests.

  Verifies that path policy denials produce correct, auditable events.
  Moved from tet_core to tet_runtime where PathResolver is native —
  eliminates cross-app dependency (tet_core cannot call
  Tet.Runtime.Tools.PathResolver when run standalone).
  """

  use ExUnit.Case, async: true

  alias Tet.Event
  alias Tet.Runtime.Tools.PathResolver

  @session_id "ses_bd0030_audit"

  defp next_seq do
    System.unique_integer([:positive, :monotonic])
  end

  # ============================================================
  # 4. Path policy enforcement — mutations outside allowed paths
  # ============================================================

  describe "4: path policy enforcement — mutations outside allowed paths" do
    test "path escape denial is representable as a tool.blocked event" do
      path_denial = PathResolver.workspace_escape_denial(
        "Resolved path escapes workspace"
      )

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: @session_id,
                 seq: next_seq(),
                 payload: %{
                   tool: "write-file",
                   decision: {:block, :path_denied},
                   path_denial: path_denial
                 }
               })

      assert event.type == :"tool.blocked"
      assert event.payload.path_denial.code == "workspace_escape"
    end

    test "path traversal denial is representable as tool.blocked event" do
      path_denial = PathResolver.workspace_escape_denial(
        "Path traversal ('..') is not allowed"
      )

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: @session_id,
                 seq: next_seq(),
                 payload: %{
                   tool: "shell",
                   decision: {:block, :path_denied},
                   path_denial: path_denial
                 }
               })

      assert event.type == :"tool.blocked"
      assert event.payload.path_denial.code == "workspace_escape"
    end

    test "null byte path denial is representable as tool.blocked event" do
      path_denial = PathResolver.invalid_path_denial(
        "Path contains null bytes"
      )

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: @session_id,
                 seq: next_seq(),
                 payload: %{
                   tool: "write-file",
                   decision: {:block, :path_denied},
                   path_denial: path_denial
                 }
               })

      assert event.type == :"tool.blocked"
      assert event.payload.path_denial.code == "invalid_arguments"
    end

    test "PathResolver.resolve rejects absolute path with structured denial" do
      result = PathResolver.resolve("/etc/passwd", "/workspace")
      assert {:error, denial} = result
      assert denial.code == "workspace_escape"
      assert denial.kind == "policy_denial"
      assert denial.retryable == false
    end

    test "PathResolver.resolve rejects path traversal with structured denial" do
      result = PathResolver.resolve("../../etc/passwd", "/workspace")
      assert {:error, denial} = result
      assert denial.code == "workspace_escape"
    end

    test "PathResolver.resolve rejects null bytes with structured denial" do
      result = PathResolver.resolve("foo\0bar", "/workspace")
      assert {:error, denial} = result
      assert denial.code == "invalid_arguments"
    end
  end
end
