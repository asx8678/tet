defmodule Tet.PlanMode.MutationGateAuditTest do
  @moduledoc """
  BD-0030: Mutation gate audit tests — path policy & integration.

  Verifies that:
    4. Path policy (deny globs, containment) blocks unsafe paths
    Integration: gate + path + event composition

  This is the main audit test file. Individual acceptance criteria
  are tested in their own split files (task, plan_mode, approval,
  events, edge_cases) to keep files focused and below the 600-line
  guideline.
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.SecurityPolicy
  alias Tet.SecurityPolicy.Profile
  alias Tet.Event
  alias Tet.Approval.BlockedAction

  import Tet.PlanMode.GateTestHelpers
  import Tet.PlanMode.MutationGateAuditTestHelpers

  @session_id Tet.PlanMode.MutationGateAuditTestHelpers.session_id()

  # ============================================================
  # 4. Path policy — deny globs block unsafe paths
  # ============================================================

  describe "4a: deny globs block mutating tool paths" do
    test "write tool targeting deny-globbed path is denied by path policy" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**"]
        })

      decision = SecurityPolicy.check(:write, %{path: "/etc/shadow"}, profile)
      assert {:denied, :denied_by_glob} = decision
    end

    test "write tool targeting nested deny-globbed path is denied" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["**/secrets/**"]
        })

      decision = SecurityPolicy.check(:write, %{path: "/workspace/app/secrets/api_key"}, profile)
      assert {:denied, :denied_by_glob} = decision
    end

    test "shell tool targeting deny-globbed path is denied by path policy" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/var/log/**"]
        })

      decision = SecurityPolicy.check(:execute, %{path: "/var/log/auth.log"}, profile)
      assert {:denied, :denied_by_glob} = decision
    end

    test "multiple deny globs — any match blocks" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**", "/var/log/**", "**/secrets/**"]
        })

      paths = ["/etc/passwd", "/var/log/syslog", "/workspace/secrets/token"]

      for path <- paths do
        decision = SecurityPolicy.check(:write, %{path: path}, profile)
        assert {:denied, :denied_by_glob} = decision, "Expected denial for #{path}"
      end
    end

    test "empty deny_globs does not block write on safe path" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: []
        })

      decision = SecurityPolicy.check(:write, %{path: "/workspace/app/new_file.ex"}, profile)
      assert decision == :allowed
    end
  end

  describe "4b: workspace containment blocks workspace escape" do
    test "write tool targeting path outside workspace is denied by sandbox" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          deny_globs: []
        })

      decision =
        SecurityPolicy.check(
          :write,
          %{
            path: "/etc/passwd",
            workspace_root: "/workspace"
          },
          profile
        )

      assert {:denied, _reason} = decision
    end

    test "write tool targeting ../ escape is denied by sandbox" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          deny_globs: []
        })

      decision =
        SecurityPolicy.check(
          :write,
          %{
            path: "../outside/file.txt",
            workspace_root: "/workspace"
          },
          profile
        )

      assert {:denied, _reason} = decision
    end

    test "write tool targeting absolute path outside workspace is denied" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          deny_globs: []
        })

      decision =
        SecurityPolicy.check(
          :write,
          %{
            path: "/tmp/malicious.sh",
            workspace_root: "/workspace"
          },
          profile
        )

      assert {:denied, _reason} = decision
    end

    test "write tool targeting path within workspace is allowed" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          deny_globs: []
        })

      decision =
        SecurityPolicy.check(
          :write,
          %{
            path: "/workspace/lib/app.ex",
            workspace_root: "/workspace"
          },
          profile
        )

      assert decision == :allowed
    end

    test "read_only sandbox denies write operations within workspace" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :read_only,
          deny_globs: []
        })

      decision =
        SecurityPolicy.check(
          :write,
          %{
            path: "/workspace/lib/app.ex",
            workspace_root: "/workspace"
          },
          profile
        )

      assert {:denied, :sandbox_read_only} = decision
    end
  end

  describe "4c: deny glob always beats allow path" do
    test "path matching both deny glob and allow path is denied" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/workspace/**/secrets/**"],
          allow_paths: ["/workspace/**"]
        })

      decision =
        SecurityPolicy.check(
          :write,
          %{
            path: "/workspace/app/secrets/token.key"
          },
          profile
        )

      assert {:denied, :denied_by_glob} = decision
    end

    test "path matching allow path but not deny glob is allowed" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/workspace/**/secrets/**"],
          allow_paths: ["/workspace/**"]
        })

      decision =
        SecurityPolicy.check(
          :write,
          %{
            path: "/workspace/lib/app.ex"
          },
          profile
        )

      assert decision == :allowed
    end
  end

  # ============================================================
  # 4d: path policy integration with gate decisions
  # ============================================================

  describe "4d: gate + path composition — gate allows but path denies" do
    test "gate-allowed write + path-denied = tool.blocked event with path_denied" do
      # Gate allows: write in execute/acting
      gate_ctx = %{mode: :execute, task_category: :acting, task_id: "t_path_4d"}
      gate_decision = Gate.evaluate(write_contract(), Policy.default(), gate_ctx)
      assert Gate.allowed?(gate_decision)

      # Path policy denies: write to deny-globbed path
      path_profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**"]
        })

      path_decision = SecurityPolicy.check(:write, %{path: "/etc/shadow"}, path_profile)
      assert {:denied, :denied_by_glob} = path_decision

      # Compose: the final decision is blocked
      assert {:ok, final_event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: @session_id,
                 seq: next_seq(),
                 payload: %{
                   tool: "write-file",
                   gate_decision: gate_decision,
                   path_decision: path_decision,
                   final_decision: {:block, :path_denied}
                 }
               })

      assert final_event.type == :"tool.blocked"
      assert final_event.payload.final_decision == {:block, :path_denied}
      assert final_event.payload.gate_decision == :allow
      assert final_event.payload.path_decision == {:denied, :denied_by_glob}
    end

    test "gate-allowed shell + workspace escape = tool.blocked event" do
      # Gate allows: shell in execute/acting
      gate_ctx = %{mode: :execute, task_category: :acting, task_id: "t_shell_escape"}
      gate_decision = Gate.evaluate(shell_contract(), Policy.default(), gate_ctx)
      assert Gate.allowed?(gate_decision)

      # Path policy denies: workspace escape
      path_profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          deny_globs: []
        })

      path_decision =
        SecurityPolicy.check(
          :execute,
          %{
            path: "/etc/passwd",
            workspace_root: "/workspace"
          },
          path_profile
        )

      assert {:denied, _} = path_decision

      assert {:ok, final_event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: @session_id,
                 seq: next_seq(),
                 payload: %{
                   tool: "shell",
                   gate_decision: gate_decision,
                   path_decision: path_decision,
                   final_decision: {:block, :path_denied}
                 }
               })

      assert final_event.type == :"tool.blocked"
      assert final_event.payload.final_decision == {:block, :path_denied}
    end

    test "gate-blocked write + path-denied = gate takes priority" do
      # Gate blocks: plan mode
      gate_ctx = %{mode: :plan, task_category: :researching, task_id: "t_gate_priority"}
      gate_decision = Gate.evaluate(write_contract(), Policy.default(), gate_ctx)
      assert Gate.blocked?(gate_decision)

      # The gate block reason is the primary audit entry
      assert {:ok, event} = persist_decision(write_contract(), gate_decision)
      assert event.type == :"tool.blocked"
      assert match?({:block, _}, event.payload.decision)
    end

    test "gate-allowed write + path-allowed = tool.started event" do
      # Gate allows
      gate_ctx = %{mode: :execute, task_category: :acting, task_id: "t_both_allow"}
      gate_decision = Gate.evaluate(write_contract(), Policy.default(), gate_ctx)
      assert Gate.allowed?(gate_decision)

      # Path allowed
      path_profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only,
          deny_globs: []
        })

      path_decision =
        SecurityPolicy.check(
          :write,
          %{
            path: "/workspace/lib/app.ex",
            workspace_root: "/workspace"
          },
          path_profile
        )

      assert path_decision == :allowed

      assert {:ok, event} = persist_decision(write_contract(), gate_decision)
      assert event.type == :"tool.started"
      assert event.payload.decision == :allow
    end
  end

  # ============================================================
  # 4e: path policy applies to all mutation types
  # ============================================================

  describe "4e: path policy applies uniformly across mutation types" do
    test "write mutation blocked by deny glob" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["**/*.key"]
        })

      decision = SecurityPolicy.check(:write, %{path: "/workspace/secret.key"}, profile)
      assert {:denied, :denied_by_glob} = decision
    end

    test "patch mutation blocked by deny glob" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["**/*.key"]
        })

      decision = SecurityPolicy.check(:patch, %{path: "/workspace/secret.key"}, profile)
      assert {:denied, :denied_by_glob} = decision
    end

    test "delete mutation blocked by deny glob" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["**/*.key"]
        })

      decision = SecurityPolicy.check(:delete, %{path: "/workspace/secret.key"}, profile)
      assert {:denied, :denied_by_glob} = decision
    end

    test "execute (shell) mutation blocked by deny glob" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["**/secrets/**"]
        })

      decision = SecurityPolicy.check(:execute, %{path: "/workspace/secrets/env"}, profile)
      assert {:denied, :denied_by_glob} = decision
    end
  end

  # ============================================================
  # Integration: blocked path actions produce audit records
  # ============================================================

  describe "integration: path-denied mutations produce audit trail" do
    test "blocked action record captures path denial context" do
      {:ok, blocked} =
        BlockedAction.new(%{
          id: "blk_path_1",
          tool_name: "write-file",
          reason: :plan_mode_blocks_mutation,
          tool_call_id: "call_path_1",
          args_summary: %{file_path: "/etc/passwd"},
          session_id: @session_id,
          task_id: "t_path_audit"
        })

      assert blocked.reason == :plan_mode_blocks_mutation
      assert blocked.tool_name == "write-file"
      assert blocked.session_id == @session_id
      assert blocked.args_summary.file_path == "/etc/passwd"
    end

    test "path-denied event and blocked action correlate" do
      # Step 1: Gate allows but path denies
      gate_ctx = %{mode: :execute, task_category: :acting, task_id: "t_corr_path"}
      gate_decision = Gate.evaluate(write_contract(), Policy.default(), gate_ctx)
      assert Gate.allowed?(gate_decision)

      # Step 2: Path denies
      path_profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**"]
        })

      path_decision = SecurityPolicy.check(:write, %{path: "/etc/shadow"}, path_profile)

      # Step 3: Persist blocked event
      assert {:ok, blocked_event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: @session_id,
                 seq: next_seq(),
                 payload: %{
                   tool: "write-file",
                   gate_decision: gate_decision,
                   path_decision: path_decision,
                   final_decision: {:block, :path_denied}
                 }
               })

      # Step 4: Create blocked action record with same correlation
      {:ok, blocked_action} =
        BlockedAction.new(%{
          id: "blk_corr_path_1",
          tool_name: "write-file",
          reason: :plan_mode_blocks_mutation,
          tool_call_id: "call_corr_path_1",
          args_summary: %{file_path: "/etc/shadow"},
          session_id: @session_id,
          task_id: "t_corr_path"
        })

      # Both share session_id for correlation
      assert blocked_event.session_id == blocked_action.session_id
      assert blocked_event.session_id == @session_id
    end

    test "full lifecycle: gate block + path block + approval rejection all persisted" do
      session = "ses_path_lifecycle"

      # 1. Gate blocks in plan mode
      gate_ctx = %{mode: :plan, task_category: :researching, task_id: "t_lifecycle"}
      gate_decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), gate_ctx)
      assert Gate.blocked?(gate_decision)

      assert {:ok, gate_event} =
               persist_decision(rogue_plan_write_contract(), gate_decision,
                 session_id: session,
                 seq: 1
               )

      assert gate_event.type == :"tool.blocked"

      # 2. Path denies even in execute mode
      path_profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["/etc/**"]
        })

      path_decision = SecurityPolicy.check(:write, %{path: "/etc/shadow"}, path_profile)
      assert {:denied, :denied_by_glob} = path_decision

      assert {:ok, path_event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: session,
                 seq: 2,
                 payload: %{
                   tool: "write-file",
                   path_decision: path_decision,
                   final_decision: {:block, :path_denied}
                 }
               })

      assert path_event.type == :"tool.blocked"

      # 3. Approval rejected — Event.approval_rejected returns struct directly
      approval_event =
        Event.approval_rejected(
          %{
            approval_id: "appr_reject_1",
            tool_call_id: "call_lifecycle_1",
            reason: "path policy denies /etc/shadow"
          },
          session_id: session,
          metadata: %{seq: 3}
        )

      assert approval_event.type == :"approval.rejected"

      # All three events share session correlation
      events = [gate_event, path_event, approval_event]
      assert Enum.all?(events, &(&1.session_id == session))
      assert length(events) == 3
    end
  end
end
