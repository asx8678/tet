defmodule Tet.EntitiesRoundTripTest do
  use ExUnit.Case, async: true

  @now ~U[2024-01-02 03:04:05Z]
  @later ~U[2024-01-02 03:05:06Z]
  @sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  @entities [
    %Tet.Workspace{
      id: "ws_prefixed_ok",
      name: "Tet Fixture",
      root_path: "/tmp/tet-fixture",
      tet_dir_path: "/tmp/tet-fixture/.tet",
      trust_state: :trusted,
      created_at: @now,
      updated_at: @later,
      metadata: %{"source" => "test"}
    },
    %Tet.Task{
      id: "task_prefixed_ok",
      session_id: "ses_prefixed_ok",
      title: "Ship storage contract",
      status: :active,
      created_at: @now,
      updated_at: @later,
      metadata: %{"phase" => "one"}
    },
    %Tet.ToolRun{
      id: "tool_run_prefixed_ok",
      session_id: "ses_prefixed_ok",
      task_id: "task_prefixed_ok",
      tool_name: "read_file",
      read_or_write: :read,
      args: %{"path" => "mix.exs"},
      status: :success,
      block_reason: :policy_checked,
      changed_files: [],
      started_at: @now,
      finished_at: @later,
      metadata: %{"runtime" => "noop"}
    },
    %Tet.Approval.Approval{
      id: "appr_prefixed_ok",
      tool_call_id: "tool_call_1",
      status: :pending,
      approver: nil,
      rationale: nil,
      created_at: @now,
      approved_at: nil,
      rejected_at: nil,
      session_id: "ses_prefixed_ok",
      task_id: "task_prefixed_ok",
      metadata: %{"reviewer" => "human"}
    },
    %Tet.Artifact{
      id: "art_prefixed_ok",
      session_id: "ses_prefixed_ok",
      kind: :diff,
      content: "diff --git a/lib/a.ex b/lib/a.ex",
      path: nil,
      sha256: @sha,
      created_at: @now,
      metadata: %{"storage" => "inline"}
    },
    %Tet.Workflow{
      id: "wf_prefixed_ok",
      session_id: "ses_prefixed_ok",
      task_id: "task_prefixed_ok",
      status: :paused_for_approval,
      created_at: @now,
      updated_at: @later,
      metadata: %{"executor" => "test"}
    },
    %Tet.WorkflowStep{
      id: "wfs_prefixed_ok",
      workflow_id: "wf_prefixed_ok",
      step_name: "provider_call:attempt:1",
      idempotency_key: @sha,
      input: %{"model" => "test-model", "attempt" => 1},
      output: %{"content" => "hello"},
      error: nil,
      status: :committed,
      started_at: @now,
      committed_at: @later,
      attempt: 1,
      metadata: %{"provider" => "mock"}
    },
    %Tet.WorkflowStep{
      id: "wfs_failed_prefixed_ok",
      workflow_id: "wf_prefixed_ok",
      step_name: "provider_call:attempt:2",
      idempotency_key: @sha,
      input: %{"model" => "test-model", "attempt" => 2},
      output: nil,
      error: %{"kind" => "provider_error", "detail" => "boom"},
      status: :failed,
      started_at: @now,
      committed_at: nil,
      attempt: 2,
      metadata: %{"provider" => "mock"}
    },
    %Tet.ErrorLog{
      id: "err_prefixed_ok",
      session_id: "ses_prefixed_ok",
      task_id: "task_prefixed_ok",
      kind: :exception,
      message: "Runtime crash in provider call",
      stacktrace: "** (RuntimeError) boom\n  provider.ex:42",
      context: %{attempt: 2},
      status: :open,
      resolved_at: nil,
      created_at: @now,
      metadata: %{"origin" => "provider"}
    },
    %Tet.ErrorLog{
      id: "err_resolved_prefixed_ok",
      session_id: "ses_prefixed_ok",
      kind: :smoke_failure,
      message: "Smoke test assertion failed",
      status: :resolved,
      resolved_at: @later,
      created_at: @now,
      metadata: %{}
    },
    %Tet.Repair{
      id: "rep_prefixed_ok",
      error_log_id: "err_prefixed_ok",
      session_id: "ses_prefixed_ok",
      strategy: :retry,
      params: %{max_attempts: 3, delay_ms: 1000},
      result: nil,
      status: :pending,
      created_at: @now,
      started_at: nil,
      completed_at: nil,
      metadata: %{"source" => "auto"}
    },
    %Tet.Repair{
      id: "rep_succeeded_prefixed_ok",
      error_log_id: "err_resolved_prefixed_ok",
      session_id: "ses_prefixed_ok",
      strategy: :patch,
      params: %{file: "test/smoke.exs", fix: "fix_assertion"},
      result: %{patched: true, test_passed: true},
      status: :succeeded,
      created_at: @now,
      started_at: @now,
      completed_at: @later,
      metadata: %{"source" => "auto"}
    }
  ]

  test "new v0.3 entities round-trip through maps" do
    Enum.each(@entities, fn entity ->
      module = entity.__struct__

      assert {:ok, ^entity} = entity |> module.to_map() |> module.from_map()
    end)
  end
end
