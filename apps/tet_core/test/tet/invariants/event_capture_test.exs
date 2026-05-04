defmodule Tet.Invariants.EventCaptureTest do
  @moduledoc """
  BD-0026 — Invariant 5: Complete event capture including blocked attempts.

  Verifies that:
  - Blocked attempts are captured as events with full context
  - All gate decision types (:allow, {:block, _}, {:guide, _}) produce
    capturable events
  - Event payload includes tool name, decision reason, task context
  - Blocked action events have full metadata for audit trail
  - Event types are in the known_types catalog
  - Tool lifecycle events (requested -> started -> finished) are complete
  - Fail-closed when event types are incomplete
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Event

  import Tet.PlanMode.GateTestHelpers

  # ============================================================
  # Blocked attempts produce events with full context
  # ============================================================

  describe "blocked attempts produce events with full context" do
    test "no_active_task block produces event with task context" do
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_blocked",
                 seq: 1,
                 payload: %{
                   decision: decision,
                   tool: "read",
                   task_id: nil,
                   task_category: :researching,
                   mode: :plan,
                   reason: :no_active_task
                 }
               })

      assert event.type == :"tool.blocked"
      assert event.payload.reason == :no_active_task
      assert event.payload.task_id == nil
      assert event.session_id == "ses_blocked"
    end

    test "plan_mode_blocks_mutation block produces event with tool and reason" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(rogue_plan_write_contract(), Policy.default(), ctx)
      assert {:block, :plan_mode_blocks_mutation} = decision

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_plan",
                 seq: 2,
                 payload: %{
                   decision: decision,
                   tool: "rogue-plan-write",
                   task_id: "t1",
                   task_category: :researching,
                   mode: :plan,
                   reason: :plan_mode_blocks_mutation
                 }
               })

      assert event.type == :"tool.blocked"
      assert event.payload.reason == :plan_mode_blocks_mutation
    end

    test "category_blocks_tool block produces event with category context" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(verifying_only_write_contract(), Policy.default(), ctx)
      assert {:block, :category_blocks_tool} = decision

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_cat",
                 seq: 3,
                 payload: %{
                   decision: decision,
                   tool: "verifying-only-write",
                   task_id: "t1",
                   task_category: :acting,
                   mode: :execute,
                   reason: :category_blocks_tool
                 }
               })

      assert event.type == :"tool.blocked"
      assert event.payload.reason == :category_blocks_tool
    end

    test "mode_not_allowed block produces event" do
      ctx = %{mode: :plan, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :mode_not_allowed} = decision

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_mode",
                 seq: 4,
                 payload: %{decision: decision, tool: "write-file", reason: :mode_not_allowed}
               })

      assert event.type == :"tool.blocked"
    end

    test "invalid_context block produces event" do
      policy = Policy.new!(%{require_active_task: false})
      ctx = %{mode: nil, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      assert match?({:block, :invalid_context}, decision)

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_invalid",
                 seq: 5,
                 payload: %{decision: decision, tool: "read", reason: :invalid_context}
               })

      assert event.type == :"tool.blocked"
    end
  end

  # ============================================================
  # Allowed decisions produce events
  # ============================================================

  describe "allowed decisions produce events" do
    test "flat :allow decision produces tool.started event" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert decision == :allow

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.started",
                 session_id: "ses_allow",
                 seq: 1,
                 payload: %{decision: :allow, tool: "read"}
               })

      assert event.type == :"tool.started"
      assert event.payload.decision == :allow
    end

    test "allow for write in execute/acting produces event" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert decision == :allow

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.started",
                 session_id: "ses_write",
                 seq: 2,
                 payload: %{decision: :allow, tool: "write-file"}
               })

      assert event.type == :"tool.started"
    end
  end

  # ============================================================
  # Guided decisions produce events
  # ============================================================

  describe "guided decisions produce events" do
    test "guide decision produces tool.requested event" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:guide, _} = decision

      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.requested",
                 session_id: "ses_guide",
                 seq: 1,
                 payload: %{decision: decision, tool: "read"}
               })

      assert event.type == :"tool.requested"
      assert {:guide, msg} = event.payload.decision
      assert is_binary(msg)
    end
  end

  # ============================================================
  # All block reasons are capturable
  # ============================================================

  describe "all block reasons are capturable as events" do
    test "every known block reason can be wrapped in an event" do
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
                   session_id: "ses_all_reasons",
                   seq: i,
                   payload: %{
                     decision: reason,
                     tool: "test-tool",
                     reason: elem(reason, 1)
                   }
                 }),
               "failed to create event for block reason #{inspect(reason)}"
      end
    end
  end

  # ============================================================
  # Full gate decision -> event pipeline
  # ============================================================

  describe "full gate decision -> event pipeline" do
    test "every gate decision from real evaluations maps to a valid event" do
      contexts = [
        %{mode: :plan, task_category: :researching, task_id: "t1"},
        %{mode: :execute, task_category: :acting, task_id: "t2"},
        %{mode: :plan, task_category: nil, task_id: "t3"},
        %{mode: :plan, task_category: :researching, task_id: nil}
      ]

      contracts = [read_contract(), write_contract(), shell_contract()]
      seq_ref = :counters.new(1, [:atomics])

      for ctx <- contexts, contract <- contracts do
        decision = Gate.evaluate(contract, Policy.default(), ctx)
        :counters.add(seq_ref, 1, 1)
        i = :counters.get(seq_ref, 1)

        event_type =
          case decision do
            :allow -> :"tool.started"
            {:block, _} -> :"tool.blocked"
            {:guide, _} -> :"tool.requested"
          end

        assert {:ok, event} =
                 Event.new(%{
                   type: event_type,
                   session_id: "ses_pipeline",
                   seq: i,
                   payload: %{decision: decision, tool: contract.name}
                 }),
               "failed to create event for #{contract.name} decision #{inspect(decision)}"

        assert event.type == event_type
      end
    end
  end

  # ============================================================
  # v03 event type catalog coverage
  # ============================================================

  describe "v03 event type catalog covers gate lifecycle" do
    test "tool.blocked is in known_types" do
      assert :"tool.blocked" in Event.known_types()
    end

    test "tool.started is in known_types" do
      assert :"tool.started" in Event.known_types()
    end

    test "tool.requested is in known_types" do
      assert :"tool.requested" in Event.known_types()
    end

    test "tool.finished is in known_types" do
      assert :"tool.finished" in Event.known_types()
    end

    test "blocked_action.created is in known_types" do
      assert :"blocked_action.created" in Event.known_types()
    end
  end

  # ============================================================
  # Blocked action event with full audit context
  # ============================================================

  describe "blocked action event with full audit context" do
    test "blocked_action event captures tool name, reason, and correlation IDs" do
      event =
        Event.blocked_action(
          %{
            blocked_action_id: "ba_001",
            tool_name: "write-file",
            reason: :plan_mode_blocks_mutation,
            tool_call_id: "tc_001"
          },
          session_id: "ses_audit",
          seq: 10,
          metadata: %{task_id: "t1", task_category: "researching"}
        )

      assert event.type == :"blocked_action.created"
      assert event.session_id == "ses_audit"
      assert event.payload.tool_name == "write-file"
      assert event.payload.reason == :plan_mode_blocks_mutation
      assert event.metadata.task_id == "t1"
    end

    test "blocked action events for every block reason" do
      reasons = [
        :no_active_task,
        :plan_mode_blocks_mutation,
        :category_blocks_tool,
        :mode_not_allowed,
        :invalid_context
      ]

      for {reason, i} <- Enum.with_index(reasons) do
        event =
          Event.blocked_action(
            %{
              blocked_action_id: "ba_#{i}",
              tool_name: "test-tool",
              reason: reason,
              tool_call_id: "tc_#{i}"
            },
            session_id: "ses_all",
            seq: i
          )

        assert event.type == :"blocked_action.created",
               "failed to create blocked_action event for #{reason}"
      end
    end
  end

  # ============================================================
  # Complete tool lifecycle event sequence
  # ============================================================

  describe "complete tool lifecycle event sequence" do
    test "requested -> started -> finished produces valid sequence" do
      session_id = "ses_lifecycle"
      tool = "read"

      # Step 1: Gate evaluation produces a decision
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:guide, _} = decision

      # Step 2: tool.requested event
      assert {:ok, requested} =
               Event.new(%{
                 type: :"tool.requested",
                 session_id: session_id,
                 seq: 1,
                 payload: %{tool: tool, decision: decision}
               })

      # Step 3: tool.started event
      assert {:ok, started} =
               Event.new(%{
                 type: :"tool.started",
                 session_id: session_id,
                 seq: 2,
                 payload: %{tool: tool}
               })

      # Step 4: tool.finished event
      assert {:ok, finished} =
               Event.new(%{
                 type: :"tool.finished",
                 session_id: session_id,
                 seq: 3,
                 payload: %{tool: tool, status: :ok}
               })

      assert requested.session_id == session_id
      assert started.session_id == session_id
      assert finished.session_id == session_id
      assert requested.seq < started.seq
      assert started.seq < finished.seq
    end

    test "blocked lifecycle: requested -> blocked (no started or finished)" do
      session_id = "ses_blocked_lifecycle"

      ctx = %{mode: :plan, task_category: :researching, task_id: nil}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert {:block, :no_active_task} = decision

      # tool.requested
      assert {:ok, requested} =
               Event.new(%{
                 type: :"tool.requested",
                 session_id: session_id,
                 seq: 1,
                 payload: %{tool: "write-file", decision: decision}
               })

      # tool.blocked (not tool.started)
      assert {:ok, blocked} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: session_id,
                 seq: 2,
                 payload: %{tool: "write-file", decision: decision}
               })

      assert requested.session_id == session_id
      assert blocked.session_id == session_id
    end
  end

  # ============================================================
  # Fail-closed: event type validation
  # ============================================================

  describe "fail closed: event type validation" do
    test "unknown event type rejected by Event.new/1" do
      assert {:error, {:invalid_event_type, _}} =
               Event.new(%{
                 type: :risky_gamble_event,
                 session_id: "ses_1",
                 seq: 1,
                 payload: %{}
               })
    end

    test "nil event type rejected by Event.new/1" do
      assert {:error, _} =
               Event.new(%{
                 type: nil,
                 session_id: "ses_1",
                 seq: 1,
                 payload: %{}
               })
    end
  end

  # ============================================================
  # Event round-trip: new -> to_map -> from_map
  # ============================================================

  describe "blocked event round-trips through serialization" do
    test "blocked action event survives to_map/from_map" do
      event =
        Event.blocked_action(
          %{
            blocked_action_id: "ba_rt",
            tool_name: "shell",
            reason: :plan_mode_blocks_mutation,
            tool_call_id: "tc_rt"
          },
          session_id: "ses_rt",
          seq: 5
        )

      mapped = Event.to_map(event)
      assert {:ok, restored} = Event.from_map(mapped)
      assert restored.type == event.type
      assert restored.session_id == event.session_id
      # Payload keys are strings after round-trip through JSON
      assert restored.payload["tool_name"] == "shell"
    end
  end
end
