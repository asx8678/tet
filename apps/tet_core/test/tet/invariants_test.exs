defmodule Tet.InvariantsTest do
  @moduledoc """
  BD-0026: Five Invariants Test Suite — orchestrator.

  This module serves as the entry point for running all five cross-phase
  invariant test suites together. It imports all invariant test modules
  and provides a comprehensive integration test that validates the
  complete invariant chain in a single pass.

  ## Invariants verified

  1. **No Mutation Without Active Task** — Mutating/executing tools
     (write, edit, patch, shell) are blocked when no active task exists.

  2. **Category-Based Tool Gating** — researching/planning categories
     only allow read-only tools; acting/verifying/debugging/documenting
     categories unlock mutating tools.

  3. **Priority-Ordered Hook Execution** — Pre-hooks execute in
     descending priority (high→low), post-hooks in ascending (low→high).
     Equal-priority tie-breaks use registration order.

  4. **Guidance After Task Operations** — Guidance messages are emitted
     after task operations, matching the active category. Gate-level
     guidance is emitted in plan-safe contexts.

  5. **Complete Event Capture** — Every gate decision type produces a
     valid event. Blocked attempts include full context. Event types
     are in the known_types catalog.

  ## Sub-modules

  - `Tet.Invariants.NoMutationWithoutTaskTest` — invariant 1
  - `Tet.Invariants.CategoryToolGatingTest` — invariant 2
  - `Tet.Invariants.HookOrderingTest` — invariant 3
  - `Tet.Invariants.GuidanceAfterOperationsTest` — invariant 4
  - `Tet.Invariants.EventCaptureTest` — invariant 5
  """

  use ExUnit.Case, async: true

  alias Tet.PlanMode.{Gate, Policy}
  alias Tet.TaskManager
  alias Tet.TaskManager.Guidance
  alias Tet.Tool.ReadOnlyContracts
  alias Tet.Event
  alias Tet.HookManager
  alias Tet.HookManager.Hook

  import Tet.PlanMode.GateTestHelpers

  # ============================================================
  # Cross-invariant integration: full lifecycle
  # ============================================================

  describe "cross-invariant: complete tool authorization lifecycle" do
    test "research task: no mutation → read allowed with guidance → guidance from task" do
      # 1. Create task state with a researching task
      state = TaskManager.new_state!(%{id: "tm_cross"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Research", category: :researching})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      # 2. Guidance should match category (Invariant 4)
      assert {:guidance, :research, msg} = TaskManager.guidance(state)
      assert msg =~ "researching"

      # 3. Category is plan-safe (Invariant 2)
      assert Guidance.plan_safe?(:researching)
      assert not Guidance.acting?(:researching)

      # 4. Read-only tool allowed in plan/researching with guidance (Invariant 2 + 4)
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      read_decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert Gate.allowed?(read_decision)
      assert Gate.guided?(read_decision)

      # 5. Mutating tool blocked in plan/researching (Invariant 1 + 2)
      write_decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert Gate.blocked?(write_decision)

      # 6. Both decisions produce valid events (Invariant 5)
      assert {:ok, _} =
               Event.new(%{
                 type: :"tool.requested",
                 session_id: "ses_cross",
                 seq: 1,
                 payload: %{decision: read_decision, tool: "read"}
               })

      assert {:ok, _} =
               Event.new(%{
                 type: :"tool.blocked",
                 session_id: "ses_cross",
                 seq: 2,
                 payload: %{decision: write_decision, tool: "write-file"}
               })
    end

    test "acting task: read allowed → write allowed → hooks compose" do
      # 1. Create task state with an acting task
      state = TaskManager.new_state!(%{id: "tm_cross2"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Implement", category: :acting})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      # 2. Guidance matches category
      assert {:guidance, :act, _msg} = TaskManager.guidance(state)

      # 3. Read-only tool allowed (no guidance in execute/acting)
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      read_decision = Gate.evaluate(read_contract(), Policy.default(), ctx)
      assert read_decision == :allow

      # 4. Mutating tool also allowed (Invariant 2)
      write_decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert Gate.allowed?(write_decision)

      # 5. Hooks compose over the lifecycle (Invariant 3)
      {pre_result, post_result} = run_hook_lifecycle(%{task_id: "t1", category: :acting})
      assert pre_result == :allowed_by_pre_hook
      assert post_result == :logged_by_post_hook
    end

    test "transition from researching to acting unlocks mutation" do
      # 1. Start with researching
      state = TaskManager.new_state!(%{id: "tm_trans"})

      {:ok, state} =
        TaskManager.add_task(state, %{id: "t1", title: "Task", category: :researching})

      {:ok, state} = TaskManager.start_and_activate(state, "t1")

      # 2. In plan mode, write is blocked
      plan_ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      assert Gate.blocked?(Gate.evaluate(write_contract(), Policy.default(), plan_ctx))

      # 3. Recategorize to acting
      {:ok, state} = TaskManager.recategorize(state, "t1", :acting)

      # 4. Now in execute mode, write is allowed
      exec_ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}
      assert Gate.allowed?(Gate.evaluate(write_contract(), Policy.default(), exec_ctx))

      # 5. Guidance updated
      assert {:guidance, :act, msg} = TaskManager.guidance(state)
      assert msg =~ "acting"
    end
  end

  # ============================================================
  # Cross-invariant: fail-closed with missing policy data
  # ============================================================

  describe "cross-invariant: all invariants fail closed with missing policy" do
    test "nil policy fields never allow mutation across all modes/categories" do
      policy =
        struct(Tet.PlanMode.Policy, %{
          plan_mode: :plan,
          safe_modes: nil,
          plan_safe_categories: nil,
          acting_categories: nil,
          require_active_task: true
        })

      for contract <- [write_contract(), shell_contract()],
          mode <- [:plan, :explore, :execute],
          category <- [:researching, :planning, :acting, :verifying, :debugging] do
        ctx = %{mode: mode, task_category: category, task_id: "t_corrupt"}
        decision = Gate.evaluate(contract, policy, ctx)

        assert Gate.blocked?(decision),
               "corrupted policy allowed #{contract.name} in #{mode}/#{category}"
      end
    end

    test "nil policy fields never emit guidance" do
      policy =
        struct(Tet.PlanMode.Policy, %{
          plan_mode: :plan,
          safe_modes: nil,
          plan_safe_categories: nil,
          acting_categories: nil,
          require_active_task: true
        })

      for contract <- ReadOnlyContracts.all(),
          mode <- [:plan, :explore],
          category <- [:researching, :planning] do
        ctx = %{mode: mode, task_category: category, task_id: "t_nil"}
        decision = Gate.evaluate(contract, policy, ctx)

        refute Gate.guided?(decision),
               "#{contract.name} emitted guidance with nil policy in #{mode}/#{category}"
      end
    end

    test "empty policy fields fail closed for mutation" do
      policy =
        struct(Tet.PlanMode.Policy, %{
          plan_mode: :plan,
          safe_modes: [],
          plan_safe_categories: [],
          acting_categories: [],
          require_active_task: true
        })

      for contract <- [write_contract(), shell_contract()],
          mode <- [:plan, :explore, :execute],
          category <- [:researching, :planning, :acting] do
        ctx = %{mode: mode, task_category: category, task_id: "t_empty"}
        decision = Gate.evaluate(contract, policy, ctx)

        assert Gate.blocked?(decision),
               "empty policy allowed #{contract.name} in #{mode}/#{category}"
      end
    end
  end

  # ============================================================
  # Cross-invariant: no active task blocks everything
  # ============================================================

  describe "cross-invariant: no active task blocks everything" do
    test "all contract types blocked when task_id is nil" do
      ctx = %{mode: :execute, task_category: :acting, task_id: nil}
      all_contracts = ReadOnlyContracts.all() ++ [write_contract(), shell_contract()]

      for contract <- all_contracts do
        decision = Gate.evaluate(contract, Policy.default(), ctx)

        assert {:block, :no_active_task} = decision,
               "#{contract.name} not blocked without active task"
      end
    end

    test "all block reasons produce valid events" do
      block_reasons = [
        :no_active_task,
        :mode_not_allowed,
        :invalid_context,
        :plan_mode_blocks_mutation,
        :category_blocks_tool
      ]

      for {reason, i} <- Enum.with_index(block_reasons) do
        assert {:ok, event} =
                 Event.new(%{
                   type: :"tool.blocked",
                   session_id: "ses_invariants",
                   seq: i,
                   payload: %{decision: {:block, reason}, tool: "test", reason: reason}
                 })

        assert event.type == :"tool.blocked"
      end
    end
  end

  # ============================================================
  # Cross-invariant: hook ordering + gate + events
  # ============================================================

  describe "cross-invariant: hook ordering composes with gate decisions" do
    test "pre-hook can modify context before gate evaluation" do
      # Hook enriches context
      enrich_hook =
        Hook.new!(%{
          id: "enrich",
          event_type: :pre,
          priority: 100,
          action_fn: fn ctx -> {:modify, Map.put(ctx, :enriched, true)} end
        })

      registry = HookManager.new() |> HookManager.register(enrich_hook)
      base_ctx = %{task_id: "t1", task_category: :acting, mode: :execute, enriched: false}

      {:ok, ctx, _} = HookManager.execute_pre(registry, base_ctx)
      assert ctx.enriched == true

      # Gate can use enriched context
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "pre-hook can block tool before gate evaluation" do
      blocker_hook =
        Hook.new!(%{
          id: "blocker",
          event_type: :pre,
          priority: 200,
          action_fn: fn _ctx -> :block end
        })

      registry = HookManager.new() |> HookManager.register(blocker_hook)
      ctx = %{task_id: "t1", task_category: :acting, mode: :execute}

      assert {:block, :hook_blocked, _} = HookManager.execute_pre(registry, ctx)

      # The gate would allow it, but the hook vetoed it first
      decision = Gate.evaluate(write_contract(), Policy.default(), ctx)
      assert Gate.allowed?(decision)
    end

    test "post-hook can emit guidance after gate allow" do
      guide_hook =
        Hook.new!(%{
          id: "guide-post",
          event_type: :post,
          priority: 10,
          action_fn: fn ctx ->
            {:guide, "Post-hook guidance", Map.put(ctx, :post_guided, true)}
          end
        })

      registry = HookManager.new() |> HookManager.register(guide_hook)
      ctx = %{task_id: "t1", task_category: :acting, mode: :execute}

      {:ok, final_ctx, guides} = HookManager.execute_post(registry, ctx)
      assert final_ctx.post_guided == true
      assert "Post-hook guidance" in guides
    end
  end

  # ============================================================
  # Cross-invariant: five invariants with hooks active via facade
  # ============================================================
  # These tests exercise the full pipeline through
  # `PlanMode.evaluate_with_hooks/4`, confirming that all five
  # cross-phase invariants hold when the hook lifecycle is active.

  describe "cross-invariant: five invariants with hooks active (BD-0024)" do
    alias Tet.PlanMode

    test "Invariant 1 + 3: pre-hook block prevents gate evaluation" do
      blocker =
        Hook.new!(%{
          id: "invariant1-blocker",
          event_type: :pre,
          priority: 200,
          action_fn: fn _ctx -> :block end
        })

      registry = HookManager.new() |> HookManager.register(blocker)
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}

      assert {:block, :hook_blocked, _} =
               PlanMode.evaluate_with_hooks(write_contract(), Policy.default(), ctx, registry)
    end

    test "Invariant 1: no active task blocks through facade with empty hooks" do
      registry = HookManager.new()
      ctx = %{mode: :plan, task_category: :researching, task_id: nil}

      {:ok, decision, _ctx, []} =
        PlanMode.evaluate_with_hooks(read_contract(), Policy.default(), ctx, registry)

      assert {:block, :no_active_task} = decision
    end

    test "Invariant 2: plan-safe category blocks mutation through facade with hooks" do
      registry = HookManager.new()
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      # rogue_plan_write_contract declares :plan in modes, so plan-mode gate triggers
      {:ok, decision, _ctx, []} =
        PlanMode.evaluate_with_hooks(rogue_plan_write_contract(), Policy.default(), ctx, registry)

      assert {:block, :plan_mode_blocks_mutation} = decision
    end

    test "Invariant 2: acting category allows mutation through facade with hooks" do
      registry = HookManager.new()
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}

      {:ok, decision, _ctx, []} =
        PlanMode.evaluate_with_hooks(write_contract(), Policy.default(), ctx, registry)

      assert Gate.allowed?(decision)
    end

    test "Invariant 3: pre-hook priority ordering is preserved through facade" do
      {:ok, order_agent} = Agent.start_link(fn -> [] end)

      h_high =
        Hook.new!(%{
          id: "high",
          event_type: :pre,
          priority: 100,
          action_fn: fn ctx ->
            Agent.update(order_agent, &(&1 ++ [:high]))
            {:continue, ctx}
          end
        })

      h_low =
        Hook.new!(%{
          id: "low",
          event_type: :pre,
          priority: 10,
          action_fn: fn ctx ->
            Agent.update(order_agent, &(&1 ++ [:low]))
            {:continue, ctx}
          end
        })

      registry =
        HookManager.new() |> HookManager.register(h_low) |> HookManager.register(h_high)

      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      {:ok, _decision, _ctx, _guides} =
        PlanMode.evaluate_with_hooks(read_contract(), Policy.default(), ctx, registry)

      assert [:high, :low] = Agent.get(order_agent, & &1)
      Agent.stop(order_agent)
    end

    test "Invariant 4: gate guidance flows through facade with post-hook enrichment" do
      guide_hook =
        Hook.new!(%{
          id: "invariant4-guide",
          event_type: :post,
          priority: 10,
          action_fn: fn ctx ->
            {:guide, "Post-hook safety reminder", Map.put(ctx, :safety_checked, true)}
          end
        })

      registry = HookManager.new() |> HookManager.register(guide_hook)
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      {:ok, decision, final_ctx, guides} =
        PlanMode.evaluate_with_hooks(read_contract(), Policy.default(), ctx, registry)

      # Gate guidance is preserved (Invariant 4)
      assert Gate.guided?(decision)
      # Post-hook guidance is accumulated
      assert "Post-hook safety reminder" in guides
      assert final_ctx.safety_checked == true
    end

    test "Invariant 5: all decision types produce valid shapes through facade" do
      registry = HookManager.new()
      policy = Policy.default()

      test_cases = [
        # allowed with guidance
        {read_contract(), %{mode: :plan, task_category: :researching, task_id: "t1"}, :guided},
        # allowed without guidance
        {read_contract(), %{mode: :execute, task_category: :acting, task_id: "t1"}, :allowed},
        # blocked: plan mode
        {write_contract(), %{mode: :plan, task_category: :researching, task_id: "t1"}, :blocked},
        # blocked: no active task
        {read_contract(), %{mode: :plan, task_category: :researching, task_id: nil}, :blocked}
      ]

      for {contract, ctx, expected} <- test_cases do
        {:ok, decision, _final_ctx, _guides} =
          PlanMode.evaluate_with_hooks(contract, policy, ctx, registry)

        case expected do
          :guided -> assert Gate.guided?(decision), "expected guidance for #{inspect(ctx)}"
          :allowed -> assert decision == :allow, "expected allow for #{inspect(ctx)}"
          :blocked -> assert Gate.blocked?(decision), "expected block for #{inspect(ctx)}"
        end

        # Every decision produces a valid event (Invariant 5)
        assert {:ok, _event} =
                 Event.new(%{
                   type: :"tool.requested",
                   session_id: "ses_hooks_active",
                   seq: :erlang.unique_integer([:positive]),
                   payload: %{decision: decision, tool: contract.name}
                 })
      end
    end

    test "full lifecycle: pre-hook enriches → gate decides → post-hook guides" do
      {:ok, trace_agent} = Agent.start_link(fn -> [] end)

      pre_hook =
        Hook.new!(%{
          id: "lifecycle-pre",
          event_type: :pre,
          priority: 100,
          action_fn: fn ctx ->
            Agent.update(trace_agent, &(&1 ++ [:pre]))
            {:modify, Map.put(ctx, :enriched, true)}
          end
        })

      post_hook =
        Hook.new!(%{
          id: "lifecycle-post",
          event_type: :post,
          priority: 10,
          action_fn: fn ctx ->
            Agent.update(trace_agent, &(&1 ++ [:post]))

            {:guide, "Be careful with writes",
             Map.put(ctx, :post_guided, Map.get(ctx, :gate_decision))}
          end
        })

      registry =
        HookManager.new() |> HookManager.register(pre_hook) |> HookManager.register(post_hook)

      # Research task: read-only allowed, write blocked
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      {:ok, read_decision, read_ctx, read_guides} =
        PlanMode.evaluate_with_hooks(read_contract(), Policy.default(), ctx, registry)

      assert Gate.guided?(read_decision)
      assert read_ctx.enriched == true
      assert "Be careful with writes" in read_guides
      assert [:pre, :post] = Agent.get(trace_agent, & &1)

      # Write should be blocked by gate; post-hooks should NOT run
      Agent.update(trace_agent, fn _ -> [] end)

      # rogue_plan_write_contract declares :plan in modes, so plan-mode gate triggers
      {:ok, write_decision, _write_ctx, _write_guides} =
        PlanMode.evaluate_with_hooks(rogue_plan_write_contract(), Policy.default(), ctx, registry)

      assert {:block, :plan_mode_blocks_mutation} = write_decision
      # Pre-hook ran, post-hook did NOT run (gate block is final)
      assert [:pre] = Agent.get(trace_agent, & &1)

      Agent.stop(trace_agent)
    end

    test "pre-hook veto prevents gate evaluation entirely" do
      veto_hook =
        Hook.new!(%{
          id: "veto",
          event_type: :pre,
          priority: 300,
          action_fn: fn _ctx -> :block end
        })

      registry = HookManager.new() |> HookManager.register(veto_hook)
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}

      # Gate would allow write, but pre-hook vetoes
      assert {:block, :hook_blocked, _} =
               PlanMode.evaluate_with_hooks(write_contract(), Policy.default(), ctx, registry)
    end

    test "post-hook veto blocks allowed gate decision" do
      post_veto =
        Hook.new!(%{
          id: "post-veto",
          event_type: :post,
          priority: 10,
          action_fn: fn _ctx -> :block end
        })

      registry = HookManager.new() |> HookManager.register(post_veto)
      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}

      # Gate allows write, but post-hook vetoes
      assert {:block, :hook_blocked, _} =
               PlanMode.evaluate_with_hooks(write_contract(), Policy.default(), ctx, registry)
    end

    test "gate block is NOT overridable by post-hooks (no-override invariant)" do
      # This hook tries to convert a block into an allow — it must fail
      overrider =
        Hook.new!(%{
          id: "overrider",
          event_type: :post,
          priority: 10,
          # Should never run because gate blocks
          action_fn: fn _ctx -> {:continue, %{override: true}} end
        })

      registry = HookManager.new() |> HookManager.register(overrider)
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      # rogue_plan_write_contract declares :plan in modes, so plan-mode gate triggers
      {:ok, decision, _ctx, _guides} =
        PlanMode.evaluate_with_hooks(rogue_plan_write_contract(), Policy.default(), ctx, registry)

      # Decision is still the gate block — overrider never ran
      assert {:block, :plan_mode_blocks_mutation} = decision
    end
  end

  # -- Helpers --

  defp run_hook_lifecycle(base_context) do
    pre_hook =
      Hook.new!(%{
        id: "pre-check",
        event_type: :pre,
        priority: 100,
        action_fn: fn ctx ->
          if Map.has_key?(ctx, :task_id) do
            {:continue, Map.put(ctx, :pre_result, :allowed_by_pre_hook)}
          else
            :block
          end
        end
      })

    post_hook =
      Hook.new!(%{
        id: "post-log",
        event_type: :post,
        priority: 10,
        action_fn: fn ctx ->
          {:continue, Map.put(ctx, :post_result, :logged_by_post_hook)}
        end
      })

    registry =
      HookManager.new()
      |> HookManager.register(pre_hook)
      |> HookManager.register(post_hook)

    {:ok, pre_ctx, _} = HookManager.execute_pre(registry, base_context)
    {:ok, post_ctx, _} = HookManager.execute_post(registry, pre_ctx)

    {pre_ctx.pre_result, post_ctx.post_result}
  end
end
