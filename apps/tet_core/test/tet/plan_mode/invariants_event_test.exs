defmodule Tet.PlanMode.InvariantsEventTest do
  @moduledoc """
  BD-0026: Invariants 4–5 test suite (guidance and event invariants)
  plus cross-cutting fail-closed policy tests.

  Verifies that guidance event emission and complete event capture
  coverage hold under all conditions, including when policy data is
  missing or malformed. Every invariant must fail closed — block
  deterministically rather than crash or allow.

  See `InvariantsGateTest` for invariants 1–3 (gate decisions).

  ## Invariants covered

  4. **Guidance Event Emission** — `{:guide, message}` is emitted
     precisely in plan-safe mode + plan-safe category + read-only
     contract. No guidance in non-plan-safe contexts. Fail-closed on
     ambiguous mode/category.

  5. **Complete Event Capture Coverage** — Every gate decision type
     (`:allow`, `{:block, _}`, `{:guide, _}`) is representable as a
     `Tet.Event` struct. All decision paths produce capturable events.
     Fail-closed when event types are incomplete.
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.Tool.ReadOnlyContracts
  alias Tet.Event

  import Tet.PlanMode.GateTestHelpers

  # ============================================================
  # Invariant 4: Guidance Event Emission
  # ============================================================
  # `{:guide, message}` is emitted precisely when:
  #   - The mode is plan-safe (plan or explore)
  #   - The category is plan-safe (researching or planning)
  #   - The contract is read-only
  # No guidance is emitted in non-plan-safe contexts.
  # Guidance messages are meaningful (non-empty, human-readable).
  # Fail-closed: ambiguous mode/category gets no guidance.

  describe "Invariant 4: guidance event emission" do
    # -- Guidance emitted in plan-safe contexts --

    test "guidance emitted for read contract in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert {:guide, msg} = decision
      assert is_binary(msg) and byte_size(msg) > 0
    end

    test "guidance emitted for list contract in plan/planning" do
      ctx = %{mode: :plan, task_category: :planning, task_id: "t1"}
      decision = Gate.evaluate(list_contract(), Policy.default(), ctx)
      assert Gate.guided?(decision)
    end

    test "guidance emitted in explore/researching" do
      ctx = %{mode: :explore, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(search_contract(), Policy.default(), ctx)
      assert Gate.guided?(decision)
    end

    test "guidance emitted for all read-only contracts in plan/researching" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        assert Gate.guided?(decision),
               "#{contract.name} should get guidance in plan/researching, got #{inspect(decision)}"
      end
    end

    # -- No guidance in non-plan-safe contexts --

    test "no guidance in execute/acting (flat :allow)" do
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert decision == :allow
      refute Gate.guided?(decision)
    end

    test "no guidance for mutating tools even in plan context (they're blocked)" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert Gate.blocked?(decision)
      refute Gate.guided?(decision)
    end

    test "no guidance when task category is acting in plan mode" do
      ctx = %{mode: :plan, task_category: :acting, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      # Acting category is not plan-safe → no guidance
      assert Gate.allowed?(decision)
      refute Gate.guided?(decision)
    end

    # -- Guidance message content --

    test "guidance message mentions plan-mode research" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:guide, msg} = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert msg =~ "Plan-mode research allowed"
    end

    test "guidance message mentions acting commitment" do
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      {:guide, msg} = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert msg =~ "acting"
    end

    # -- Fail-closed: no guidance on ambiguous data --

    test "no guidance when mode is non-plan-safe (execute)" do
      ctx = %{mode: :execute, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      refute Gate.guided?(decision)
    end

    test "no guidance when category is nil (blocked before guidance)" do
      ctx = %{mode: :plan, task_category: nil, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert Gate.blocked?(decision)
      refute Gate.guided?(decision)
    end

    test "fail closed: no guidance with empty safe_modes policy" do
      policy = empty_safe_modes_policy()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      # Empty safe_modes → plan_safe_mode? false → no guidance
      refute Gate.guided?(decision),
             "empty safe_modes should not emit guidance, got #{inspect(decision)}"
    end

    test "fail closed: no guidance with empty plan_safe_categories policy" do
      policy = empty_plan_safe_categories_policy()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      decision = Gate.evaluate(read_contract(), policy, ctx)
      # Empty plan_safe_categories → category not plan-safe → no guidance
      refute Gate.guided?(decision),
             "empty plan_safe_categories should not emit guidance, got #{inspect(decision)}"
    end
  end

  # ============================================================
  # Invariant 5: Complete Event Capture Coverage
  # ============================================================
  # Every gate decision type must be representable as a Tet.Event.
  # This ensures the audit trail can capture the complete lifecycle
  # of tool authorization: allowed, blocked, or guided.
  # All decision paths produce capturable events. Fail-closed when
  # event types are incomplete or event construction fails.

  describe "Invariant 5: complete event capture coverage" do
    # -- :allow decision maps to event --

    test ":allow decision is representable as a tool.started event" do
      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.started",
                 session_id: "ses_1",
                 seq: 1,
                 payload: %{decision: :allow, tool: "read"}
               })

      assert event.type == :"tool.started"
      assert event.payload.decision == :allow
    end

    # -- {:block, reason} decisions map to events --

    test "{:block, :no_active_task} is representable as tool.blocked event" do
      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_1",
                 seq: 2,
                 payload: %{decision: {:block, :no_active_task}, tool: "write"}
               })

      assert event.type == :"tool.blocked"
    end

    test "{:block, :plan_mode_blocks_mutation} is representable as tool.blocked event" do
      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_1",
                 seq: 3,
                 payload: %{decision: {:block, :plan_mode_blocks_mutation}, tool: "shell"}
               })

      assert event.type == :"tool.blocked"
    end

    test "{:block, :category_blocks_tool} is representable as tool.blocked event" do
      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_1",
                 seq: 4,
                 payload: %{decision: {:block, :category_blocks_tool}, tool: "write"}
               })

      assert event.type == :"tool.blocked"
    end

    test "{:block, :invalid_context} is representable as tool.blocked event" do
      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_1",
                 seq: 5,
                 payload: %{decision: {:block, :invalid_context}, tool: "read"}
               })

      assert event.type == :"tool.blocked"
    end

    test "{:block, :mode_not_allowed} is representable as tool.blocked event" do
      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_1",
                 seq: 6,
                 payload: %{decision: {:block, :mode_not_allowed}, tool: "write"}
               })

      assert event.type == :"tool.blocked"
    end

    # -- {:guide, message} decision maps to event --

    test "{:guide, _} decision is representable as tool.requested event" do
      assert {:ok, event} =
               Event.new(%{
                 type: :"tool.requested",
                 session_id: "ses_1",
                 seq: 7,
                 payload: %{
                   decision: {:guide, "Plan-mode research allowed"},
                   tool: "read"
                 }
               })

      assert event.type == :"tool.requested"
    end

    # -- All observed block reasons are capturable --

    test "every block reason produced by the gate is capturable as an event" do
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
                   session_id: "ses_capture",
                   seq: i,
                   payload: %{decision: reason, tool: "test"}
                 }),
               "failed to create event for block reason #{inspect(reason)}"
      end
    end

    # -- Full decision-to-event pipeline for real gate evaluations --

    test "every gate decision from real evaluations produces a valid event" do
      contexts = [
        %{mode: :plan, task_category: :researching, task_id: "t1"},
        %{mode: :execute, task_category: :acting, task_id: "t2"}
      ]

      contracts = [read_contract(), write_contract()]
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
               "failed to create #{event_type} event for decision #{inspect(decision)}"

        assert event.type == event_type
      end
    end

    # -- v03 event types cover the gate lifecycle --

    test "v03 known_types includes tool.blocked for blocked decisions" do
      assert :"tool.blocked" in Event.known_types()
    end

    test "v03 known_types includes tool.started for allowed decisions" do
      assert :"tool.started" in Event.known_types()
    end

    test "v03 known_types includes tool.requested for guided decisions" do
      assert :"tool.requested" in Event.known_types()
    end

    test "v03 known_types includes tool.finished for completion events" do
      assert :"tool.finished" in Event.known_types()
    end

    # -- Fail-closed: invalid event type is rejected --

    test "fail closed: unknown event type is rejected by Event.new/1" do
      assert {:error, {:invalid_event_type, :tool_risky_gamble}} =
               Event.new(%{
                 type: :tool_risky_gamble,
                 session_id: "ses_1",
                 seq: 1,
                 payload: %{}
               })
    end

    test "fail closed: event with nil type is rejected" do
      assert {:error, _} =
               Event.new(%{
                 type: nil,
                 session_id: "ses_1",
                 seq: 1,
                 payload: %{}
               })
    end

    # -- Complete lifecycle: requested → started → finished --

    test "complete tool lifecycle produces capturable event sequence" do
      session_id = "ses_lifecycle"
      tool = "read"

      assert {:ok, requested} =
               Event.new(%{
                 type: :"tool.requested",
                 session_id: session_id,
                 seq: 1,
                 payload: %{tool: tool, decision: {:guide, "Plan-mode research allowed"}}
               })

      assert {:ok, started} =
               Event.new(%{
                 type: :"tool.started",
                 session_id: session_id,
                 seq: 2,
                 payload: %{tool: tool}
               })

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
  end

  # ============================================================
  # Cross-cutting: all invariants fail closed with missing policy
  # ============================================================

  describe "cross-cutting: fail closed with missing policy data" do
    test "nil safe_modes never widens to allow mutation in plan-safe modes" do
      policy = nil_safe_modes_policy()

      for mode <- [:plan, :explore],
          category <- [:researching, :planning, :acting],
          contract <- [write_contract(), shell_contract()] do
        ctx = %{mode: mode, task_category: category, task_id: "t_fail"}
        decision = Gate.evaluate(contract, policy, ctx)

        assert Gate.blocked?(decision),
               "mutation allowed with nil safe_modes in #{mode}/#{category}: #{inspect(decision)}"
      end
    end

    test "nil plan_safe_categories never emits guidance" do
      policy =
        struct(Policy, %{
          plan_mode: :plan,
          safe_modes: [:plan, :explore],
          plan_safe_categories: nil,
          acting_categories: [:acting],
          require_active_task: true
        })

      ctx = %{mode: :plan, task_category: :researching, task_id: "t_nil_cat"}

      for contract <- ReadOnlyContracts.all() do
        decision = Gate.evaluate(contract, policy, ctx)

        refute Gate.guided?(decision),
               "#{contract.name} got guidance with nil plan_safe_categories: #{inspect(decision)}"
      end
    end

    test "structurally invalid policy never allows mutation" do
      policy =
        struct(Policy, %{
          plan_mode: nil,
          safe_modes: nil,
          plan_safe_categories: nil,
          acting_categories: nil,
          require_active_task: true
        })

      for contract <- [write_contract(), shell_contract()] do
        ctx = %{mode: :execute, task_category: :acting, task_id: "t_corrupt"}
        decision = Gate.evaluate(contract, policy, ctx)

        assert Gate.blocked?(decision),
               "corrupted policy allowed mutation for #{contract.name}: #{inspect(decision)}"
      end
    end

    test "structurally invalid policy still allows read-only in some paths" do
      policy =
        struct(Policy, %{
          plan_mode: :plan,
          safe_modes: [],
          plan_safe_categories: [],
          acting_categories: [],
          require_active_task: true
        })

      for mode <- [:plan, :explore, :execute],
          category <- [:researching, :planning, :acting] do
        ctx = %{mode: mode, task_category: category, task_id: "t_no_crash"}

        for contract <- ReadOnlyContracts.all() do
          decision = Gate.evaluate(contract, policy, ctx)

          assert match?(:allow, decision) or match?({:block, _}, decision) or
                   match?({:guide, _}, decision)
        end
      end
    end
  end
end
