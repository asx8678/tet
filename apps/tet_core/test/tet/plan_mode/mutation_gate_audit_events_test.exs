defmodule Tet.PlanMode.MutationGateAuditEventsTest do
  @moduledoc """
  BD-0030: Mutation gate audit tests — event capture & cross-cutting.

  Verifies that:
    5. Event capture — both blocked and approved attempts generate
       auditable events with correct types and payloads
    Cross-cutting: complete audit trail integrity, gate+path composition
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Event

  import Tet.PlanMode.GateTestHelpers
  import Tet.PlanMode.MutationGateAuditTestHelpers

  @session_id Tet.PlanMode.MutationGateAuditTestHelpers.session_id()

  # ============================================================
  # 5. Event capture
  # ============================================================

  describe "5: event capture — both blocked and approved attempts generate auditable events" do
    test "blocked attempt generates valid tool.blocked event with all metadata" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_ev_block"}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)

      assert {:ok, event} = persist_decision(rogue_plan_write_contract(), decision,
        session_id: "ses_audit_block", seq: 100)

      assert event.type == :"tool.blocked"
      assert event.session_id == "ses_audit_block"
      assert event.seq == 100
      assert event.payload.tool == "rogue-plan-write"
      assert event.payload.decision == {:block, :plan_mode_blocks_mutation}
      assert event.payload.mutation == :write
      assert event.payload.read_only == false
    end

    test "approved attempt generates valid tool.started event with all metadata" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t_ev_allow"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)

      assert {:ok, event} = persist_decision(write_contract(), decision,
        session_id: "ses_audit_allow", seq: 200)

      assert event.type == :"tool.started"
      assert event.session_id == "ses_audit_allow"
      assert event.seq == 200
      assert event.payload.tool == "write-file"
      assert event.payload.decision == :allow
    end

    test "guided attempt (read-only in plan) generates tool.requested event" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t_ev_guide"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:guide, _msg} = decision

      assert {:ok, event} = persist_decision(read_contract(), decision,
        session_id: "ses_audit_guide", seq: 300)

      assert event.type == :"tool.requested"
      assert event.payload.tool == "read"
      assert match?({:guide, _}, event.payload.decision)
    end

    test "every gate decision type produces a distinct, valid event type" do
      scenarios = [
        # {description, contract, context, expected_decision_shape}
        {"blocked: no task", write_contract(),
         %{mode: :execute, task_category: :acting, task_id: nil},
         {:block, :no_active_task}},
        {"blocked: plan mode", rogue_plan_write_contract(),
         %{mode: :plan, task_category: :researching, task_id: "t"},
         {:block, :plan_mode_blocks_mutation}},
        {"blocked: mode not allowed", write_contract(),
         %{mode: :plan, task_category: :acting, task_id: "t"},
         {:block, :mode_not_allowed}},
        {"allowed: execute/acting", write_contract(),
         %{mode: :execute, task_category: :acting, task_id: "t"},
         :allow},
        {"guided: plan/researching read", read_contract(),
         %{mode: :plan, task_category: :researching, task_id: "t"},
         :guided_read}
      ]

      for {desc, contract, ctx, expected_shape} <- scenarios do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        # Verify decision shape
        case expected_shape do
          {:block, reason} ->
            assert {:block, ^reason} = decision,
                   "Scenario #{desc}: expected {:block, #{inspect(reason)}}, got #{inspect(decision)}"
          :allow ->
            assert decision == :allow,
                   "Scenario #{desc}: expected :allow, got #{inspect(decision)}"
          :guided_read ->
            assert match?({:guide, _}, decision),
                   "Scenario #{desc}: expected {:guide, _}, got #{inspect(decision)}"
        end

        # Verify the decision is persistable as an event
        assert {:ok, event} = persist_decision(contract, decision),
               "Scenario #{desc}: failed to persist decision #{inspect(decision)}"

        # Verify the event type matches the decision
        expected_type = decision_to_event_type(expected_shape)
        assert event.type == expected_type,
               "Scenario #{desc}: expected event type #{inspect(expected_type)}, got #{inspect(event.type)}"
      end
    end

    test "blocked and approved events have consistent correlation metadata" do
      session = "ses_correlation_test"

      # Blocked (use rogue contract that declares :plan mode)
      blocked_ctx = %{mode: :plan, task_category: :researching, task_id: "t_corr"}
      blocked_decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), blocked_ctx)

      assert {:ok, blocked_event} = persist_decision(rogue_plan_write_contract(), blocked_decision,
        session_id: session, seq: 1)

      # Approved
      approved_ctx = %{mode: :execute, task_category: :acting, task_id: "t_corr"}
      approved_decision = Gate.evaluate(write_contract(), Policy.default(), approved_ctx)

      assert {:ok, approved_event} = persist_decision(write_contract(), approved_decision,
        session_id: session, seq: 2)

      # Same session correlation
      assert blocked_event.session_id == approved_event.session_id
      assert blocked_event.session_id == session

      # Ordered seq numbers
      assert blocked_event.seq < approved_event.seq
    end

    test "all observed block reasons produce persistable events" do
      block_reasons = [
        {:block, :no_active_task},
        {:block, :mode_not_allowed},
        {:block, :invalid_context},
        {:block, :plan_mode_blocks_mutation},
        {:block, :category_blocks_tool}
      ]

      for {reason, i} <- Enum.with_index(block_reasons) do
        assert {:ok, _event} =
                 Event.new(%{
                   type: :"tool.blocked",
                   session_id: @session_id,
                   seq: 1000 + i,
                   payload: %{decision: reason, tool: "write-file", mutation: :write}
                 }),
               "Failed to persist block reason #{inspect(reason)}"
      end
    end
  end

  # ============================================================
  # Gate + path composition (moved from section 4 — uses Gate
  # so stays in tet_core to avoid cross-app dependency)
  # ============================================================

  describe "gate+path: gate-allowed + path-denied produces auditable blocked event" do
    test "gate-allowed + path-denied composes into tool.blocked event" do
      # The gate allows the mutation, but path policy denies it.
      # This composition should still produce a tool.blocked event.
      gate_ctx = %{mode: :execute, task_category: :acting, task_id: "t_path_comp"}
      gate_decision = Gate.evaluate(write_contract(), Policy.default(), gate_ctx)
      assert Gate.allowed?(gate_decision)

      # Simulate path resolution failure (PathResolver is in tet_runtime;
      # here we test the event structure that would result)
      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: @session_id,
                 seq: next_seq(),
                 payload: %{
                   tool: "write-file",
                   gate_decision: gate_decision,
                   path_decision: {:error, %{code: "workspace_escape", kind: "policy_denial"}},
                   final_decision: {:block, :path_denied}
                 }
               })

      assert event.type == :"tool.blocked"
      assert event.payload.final_decision == {:block, :path_denied}
      assert event.payload.gate_decision == :allow
    end

    test "gate-blocked + path-denied produces blocked event (gate takes priority)" do
      gate_ctx = %{mode: :plan, task_category: :researching, task_id: "t_both_block"}
      gate_decision = Gate.evaluate(write_contract(), Policy.default(), gate_ctx)
      assert Gate.blocked?(gate_decision)

      # Even if path were also denied, the gate block reason should be
      # the primary audit entry.
      assert {:ok, event} = persist_decision(write_contract(), gate_decision)
      assert event.type == :"tool.blocked"
      assert match?({:block, _}, event.payload.decision)
    end
  end

  # ============================================================
  # Cross-cutting: complete audit trail integrity
  # ============================================================

  describe "cross-cutting: complete audit trail integrity" do
    test "full lifecycle: multiple decisions produce ordered audit trail" do
      session = "ses_lifecycle_audit"

      decisions = [
        # 1. Read-only guided in plan/researching
        {read_contract(), %{mode: :plan, task_category: :researching, task_id: "t_lc1"}},
        # 2. Write blocked in plan mode (use rogue contract that declares :plan mode)
        {rogue_plan_write_contract(), %{mode: :plan, task_category: :researching, task_id: "t_lc1"}},
        # 3. Write blocked (no task)
        {write_contract(), %{mode: :execute, task_category: :acting, task_id: nil}},
        # 4. Write allowed in execute/acting
        {write_contract(), %{mode: :execute, task_category: :acting, task_id: "t_lc2"}}
      ]

      events =
        for {contract, ctx} <- decisions do
          seq = System.unique_integer([:positive, :monotonic])

          decision = Gate.evaluate(contract, Policy.default(), ctx)
          assert {:ok, event} = persist_decision(contract, decision,
            session_id: session, seq: seq)

          event
        end

      # Verify event ordering
      assert length(events) == 4
      seqs = Enum.map(events, & &1.seq)
      assert seqs == Enum.sort(seqs), "Events should have monotonically increasing seq numbers"

      # Verify event types in order
      assert Enum.at(events, 0).type == :"tool.requested"  # guided read
      assert Enum.at(events, 1).type == :"tool.blocked"     # blocked write
      assert Enum.at(events, 2).type == :"tool.blocked"     # blocked write (no task)
      assert Enum.at(events, 3).type == :"tool.started"    # approved write

      # All events share the same session
      assert Enum.all?(events, &(&1.session_id == session))
    end

    test "every gate decision is persistable — exhaustive sweep" do
      contracts = [read_contract(), write_contract(), shell_contract()]

      contexts = [
        %{mode: :plan, task_category: :researching, task_id: "t_ex1"},
        %{mode: :plan, task_category: :planning, task_id: "t_ex2"},
        %{mode: :plan, task_category: :acting, task_id: "t_ex3"},
        %{mode: :explore, task_category: :researching, task_id: "t_ex4"},
        %{mode: :execute, task_category: :researching, task_id: "t_ex5"},
        %{mode: :execute, task_category: :acting, task_id: "t_ex6"},
        %{mode: :execute, task_category: :verifying, task_id: "t_ex7"}
      ]

      for contract <- contracts, ctx <- contexts do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        assert {:ok, _event} = persist_decision(contract, decision),
               "Failed to persist decision for #{contract.name} in #{ctx.mode}/#{ctx.task_category}: #{inspect(decision)}"
      end
    end

    test "approval event types exist in Event.known_types" do
      # Verify the audit event types are registered in the event system
      assert :"tool.blocked" in Event.known_types()
      assert :"tool.started" in Event.known_types()
      assert :"tool.requested" in Event.known_types()
      assert :"approval.created" in Event.known_types()
      assert :"approval.approved" in Event.known_types()
      assert :"approval.rejected" in Event.known_types()
    end

    test "approval lifecycle events are persistable" do
      # Blocked mutation → approval.created + approval.rejected
      assert {:ok, created} =
               Event.new(%{
                 type: :"approval.created",
                 session_id: @session_id,
                 seq: next_seq(),
                 payload: %{tool: "write-file", reason: "mutation requires approval"}
               })

      assert created.type == :"approval.created"

      assert {:ok, rejected} =
               Event.new(%{
                 type: :"approval.rejected",
                 session_id: @session_id,
                 seq: next_seq(),
                 payload: %{tool: "write-file", reason: "plan mode blocks mutation"}
               })

      assert rejected.type == :"approval.rejected"

      # Approved mutation → approval.created + approval.approved
      assert {:ok, approved} =
               Event.new(%{
                 type: :"approval.approved",
                 session_id: @session_id,
                 seq: next_seq(),
                 payload: %{tool: "write-file", reason: "acting task with valid context"}
               })

      assert approved.type == :"approval.approved"
    end

    test "blocked and approved attempts are BOTH persisted (acceptance criterion)" do
      # This is the core acceptance criterion: both blocked and approved
      # attempts must be persisted in the audit trail.
      session = "ses_acceptance_criterion"

      # Blocked attempt (use rogue contract that declares :plan mode)
      blocked_ctx = %{mode: :plan, task_category: :researching, task_id: "t_acc"}
      blocked_decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), blocked_ctx)
      assert Gate.blocked?(blocked_decision)

      assert {:ok, blocked_event} = persist_decision(rogue_plan_write_contract(), blocked_decision,
        session_id: session, seq: 1)
      assert blocked_event.type == :"tool.blocked"

      # Approved attempt
      approved_ctx = %{mode: :execute, task_category: :acting, task_id: "t_acc"}
      approved_decision = Gate.evaluate(write_contract(), Policy.default(), approved_ctx)
      assert Gate.allowed?(approved_decision)

      assert {:ok, approved_event} = persist_decision(write_contract(), approved_decision,
        session_id: session, seq: 2)
      assert approved_event.type == :"tool.started"

      # BOTH are persisted — the acceptance criterion is met
      assert blocked_event.session_id == approved_event.session_id
      assert blocked_event.payload.mutation == :write
      assert approved_event.payload.mutation == :write
      refute blocked_event.type == approved_event.type
    end
  end
end
