defmodule Tet.HookManagerTest do
  use ExUnit.Case, async: true

  alias Tet.HookManager
  alias Tet.HookManager.Hook
  alias Tet.Tool.Contract
  alias Tet.Tool.ReadOnlyContracts

  describe "new/0" do
    test "returns an empty registry" do
      reg = HookManager.new()

      assert reg.pre_hooks == []
      assert reg.post_hooks == []
    end
  end

  describe "register/2" do
    test "registers a pre-hook" do
      hook = build_pre_hook("h1", 100)
      reg = HookManager.new() |> HookManager.register(hook)

      assert length(reg.pre_hooks) == 1
      assert List.first(reg.pre_hooks).id == "h1"
    end

    test "registers a post-hook" do
      hook = build_post_hook("h1", 100)
      reg = HookManager.new() |> HookManager.register(hook)

      assert length(reg.post_hooks) == 1
    end

    test "replaces hook with same id (last-write-wins)" do
      hook1 = build_pre_hook("dup", 10, fn ctx -> {:continue, Map.put(ctx, :from, 1)} end)
      hook2 = build_pre_hook("dup", 20, fn ctx -> {:continue, Map.put(ctx, :from, 2)} end)

      reg = HookManager.new() |> HookManager.register(hook1) |> HookManager.register(hook2)

      assert length(reg.pre_hooks) == 1
      {:ok, ctx, _} = HookManager.execute_pre(reg, %{})
      assert ctx.from == 2
    end

    test "registers multiple pre-hooks" do
      hooks = Enum.map(1..3, fn i -> build_pre_hook("h#{i}", i * 10) end)
      reg = Enum.reduce(hooks, HookManager.new(), &HookManager.register(&2, &1))

      assert length(reg.pre_hooks) == 3
    end

    test "registers both pre and post hooks" do
      pre = build_pre_hook("pre-1", 0)
      post = build_post_hook("post-1", 0)

      reg = HookManager.new() |> HookManager.register(pre) |> HookManager.register(post)

      assert length(reg.pre_hooks) == 1
      assert length(reg.post_hooks) == 1
    end
  end

  describe "deregister/2" do
    test "removes a hook by id" do
      h1 = build_pre_hook("keep", 10)
      h2 = build_pre_hook("remove", 20)

      reg =
        HookManager.new()
        |> HookManager.register(h1)
        |> HookManager.register(h2)
        |> HookManager.deregister("remove")

      assert length(reg.pre_hooks) == 1
      assert List.first(reg.pre_hooks).id == "keep"
    end

    test "removes from both pre and post lists" do
      pre = build_pre_hook("shared", 10)
      post = build_post_hook("shared", 10)

      reg =
        HookManager.new()
        |> HookManager.register(pre)
        |> HookManager.register(post)
        |> HookManager.deregister("shared")

      assert reg.pre_hooks == []
      assert reg.post_hooks == []
    end

    test "no-op for unknown id" do
      reg = HookManager.new() |> HookManager.deregister("ghost")
      assert reg.pre_hooks == []
    end
  end

  describe "execute_pre/2" do
    test "executes hooks in descending priority order (high to low)" do
      h_high =
        build_pre_hook("high", 100, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:high])}
        end)

      h_mid =
        build_pre_hook("mid", 50, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:mid])}
        end)

      h_low =
        build_pre_hook("low", 10, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:low])}
        end)

      reg =
        HookManager.new()
        |> HookManager.register(h_low)
        |> HookManager.register(h_high)
        |> HookManager.register(h_mid)

      {:ok, ctx, _} = HookManager.execute_pre(reg, %{})
      assert ctx.order == [:high, :mid, :low]
    end

    test "equal priority hooks execute in registration order" do
      h_first =
        build_pre_hook("first", 0, fn ctx ->
          {:continue, Map.put(ctx, :trace, Map.get(ctx, :trace, []) ++ [:first])}
        end)

      h_second =
        build_pre_hook("second", 0, fn ctx ->
          {:continue, Map.put(ctx, :trace, Map.get(ctx, :trace, []) ++ [:second])}
        end)

      h_third =
        build_pre_hook("third", 0, fn ctx ->
          {:continue, Map.put(ctx, :trace, Map.get(ctx, :trace, []) ++ [:third])}
        end)

      reg =
        HookManager.new()
        |> HookManager.register(h_first)
        |> HookManager.register(h_second)
        |> HookManager.register(h_third)

      {:ok, ctx, _} = HookManager.execute_pre(reg, %{})
      assert ctx.trace == [:first, :second, :third]
    end

    test "block short-circuits execution" do
      h1 = build_pre_hook("blocker", 100, fn _ctx -> :block end)
      h2 = build_pre_hook("never-runs", 50, fn _ctx -> {:continue, %{ran: true}} end)

      reg = HookManager.new() |> HookManager.register(h1) |> HookManager.register(h2)
      assert {:block, :hook_blocked, _ctx} = HookManager.execute_pre(reg, %{})
    end

    test "modify transforms context for next hook" do
      h1 = build_pre_hook("mod", 100, fn ctx -> {:modify, Map.put(ctx, :step, 1)} end)

      h2 =
        build_pre_hook("check", 50, fn ctx -> {:continue, Map.put(ctx, :final, ctx.step + 1)} end)

      reg = HookManager.new() |> HookManager.register(h1) |> HookManager.register(h2)
      {:ok, ctx, _} = HookManager.execute_pre(reg, %{})
      assert ctx.final == 2
    end

    test "guide accumulates messages" do
      h1 = build_pre_hook("g1", 100, fn ctx -> {:guide, "first", Map.put(ctx, :a, 1)} end)
      h2 = build_pre_hook("g2", 50, fn ctx -> {:guide, "second", Map.put(ctx, :b, 2)} end)

      reg = HookManager.new() |> HookManager.register(h1) |> HookManager.register(h2)
      {:ok, ctx, guides} = HookManager.execute_pre(reg, %{})
      assert ctx.a == 1
      assert ctx.b == 2
      assert guides == ["first", "second"]
    end

    test "mixed actions work together" do
      h1 = build_pre_hook("mod", 100, fn ctx -> {:modify, Map.put(ctx, :a, 1)} end)
      h2 = build_pre_hook("guide", 50, fn ctx -> {:guide, "checkpoint", Map.put(ctx, :b, 2)} end)
      h3 = build_pre_hook("cont", 0, fn ctx -> {:continue, Map.put(ctx, :c, 3)} end)

      reg =
        HookManager.new()
        |> HookManager.register(h1)
        |> HookManager.register(h2)
        |> HookManager.register(h3)

      {:ok, ctx, guides} = HookManager.execute_pre(reg, %{})
      assert ctx == %{a: 1, b: 2, c: 3}
      assert guides == ["checkpoint"]
    end

    test "invalid action returns block" do
      h1 = build_pre_hook("bad", 100, fn _ctx -> :invalid_action end)
      reg = HookManager.new() |> HookManager.register(h1)

      assert {:block, :invalid_hook_action, _ctx} = HookManager.execute_pre(reg, %{})
    end

    test "empty pre_hooks returns ok with unchanged context" do
      assert {:ok, %{a: 1}, []} = HookManager.execute_pre(HookManager.new(), %{a: 1})
    end
  end

  describe "execute_post/2" do
    test "executes hooks in ascending priority order (low to high)" do
      h_low =
        build_post_hook("low", 10, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:low])}
        end)

      h_mid =
        build_post_hook("mid", 50, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:mid])}
        end)

      h_high =
        build_post_hook("high", 100, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:high])}
        end)

      reg =
        HookManager.new()
        |> HookManager.register(h_low)
        |> HookManager.register(h_high)
        |> HookManager.register(h_mid)

      {:ok, ctx, _} = HookManager.execute_post(reg, %{})
      assert ctx.order == [:low, :mid, :high]
    end

    test "equal priority hooks execute in registration order" do
      h_a =
        build_post_hook("a", 0, fn ctx ->
          {:continue, Map.put(ctx, :trace, Map.get(ctx, :trace, []) ++ [:a])}
        end)

      h_b =
        build_post_hook("b", 0, fn ctx ->
          {:continue, Map.put(ctx, :trace, Map.get(ctx, :trace, []) ++ [:b])}
        end)

      reg = HookManager.new() |> HookManager.register(h_a) |> HookManager.register(h_b)

      {:ok, ctx, _} = HookManager.execute_post(reg, %{})
      assert ctx.trace == [:a, :b]
    end

    test "block short-circuits post hooks" do
      h1 = build_post_hook("b1", 10, fn _ctx -> :block end)
      h2 = build_post_hook("b2", 20, fn _ctx -> {:continue, %{ran: true}} end)

      reg = HookManager.new() |> HookManager.register(h1) |> HookManager.register(h2)
      assert {:block, :hook_blocked, _ctx} = HookManager.execute_post(reg, %{})
    end

    test "modify and guide work in post hooks" do
      h1 = build_post_hook("mod", 10, fn ctx -> {:modify, Map.put(ctx, :x, 1)} end)
      h2 = build_post_hook("guide", 20, fn ctx -> {:guide, "done", Map.put(ctx, :y, 2)} end)

      reg = HookManager.new() |> HookManager.register(h1) |> HookManager.register(h2)

      {:ok, ctx, guides} = HookManager.execute_post(reg, %{})
      assert ctx.x == 1
      assert ctx.y == 2
      assert guides == ["done"]
    end

    test "empty post_hooks returns ok" do
      assert {:ok, %{}, []} = HookManager.execute_post(HookManager.new(), %{})
    end
  end

  describe "merge/2" do
    test "merges two registries by concatenating hook lists" do
      h1 = build_pre_hook("r1-pre", 10)
      h2 = build_post_hook("r1-post", 10)
      h3 = build_pre_hook("r2-pre", 20)
      h4 = build_post_hook("r2-post", 20)

      r1 = HookManager.new() |> HookManager.register(h1) |> HookManager.register(h2)
      r2 = HookManager.new() |> HookManager.register(h3) |> HookManager.register(h4)

      merged = HookManager.merge(r1, r2)

      assert length(merged.pre_hooks) == 2
      assert length(merged.post_hooks) == 2
      assert List.first(merged.pre_hooks).id == "r1-pre"
      assert List.last(merged.pre_hooks).id == "r2-pre"
    end

    test "preserves duplicate ids" do
      h1 = build_pre_hook("dup", 10)
      h2 = build_pre_hook("dup", 20)

      merged =
        HookManager.merge(
          HookManager.new() |> HookManager.register(h1),
          HookManager.new() |> HookManager.register(h2)
        )

      assert length(merged.pre_hooks) == 2
    end
  end

  describe "hook_ids/1" do
    test "returns ids grouped by event type" do
      reg =
        HookManager.new()
        |> HookManager.register(build_pre_hook("p1", 10))
        |> HookManager.register(build_pre_hook("p2", 20))
        |> HookManager.register(build_post_hook("o1", 10))

      ids = HookManager.hook_ids(reg)
      assert ids.pre == ["p1", "p2"]
      assert ids.post == ["o1"]
    end
  end

  describe "count/1" do
    test "returns hook counts" do
      reg =
        HookManager.new()
        |> HookManager.register(build_pre_hook("p1", 10))
        |> HookManager.register(build_post_hook("o1", 10))

      assert HookManager.count(reg) == %{pre: 1, post: 1}
    end

    test "empty registry has zero counts" do
      assert HookManager.count(HookManager.new()) == %{pre: 0, post: 0}
    end
  end

  describe "integration: composability" do
    test "core and plugin registries can be merged and executed" do
      core_hook =
        build_pre_hook("core-vet", 200, fn ctx ->
          if ctx.valid? do
            {:continue, ctx}
          else
            :block
          end
        end)

      plugin_hook =
        build_pre_hook("plugin-audit", 100, fn ctx ->
          {:modify, Map.put(ctx, :audited, true)}
        end)

      core_reg = HookManager.new() |> HookManager.register(core_hook)
      plugin_reg = HookManager.new() |> HookManager.register(plugin_hook)
      combined = HookManager.merge(core_reg, plugin_reg)

      # Valid context passes both hooks
      assert {:ok, ctx, _} = HookManager.execute_pre(combined, %{valid?: true})
      assert ctx.audited == true

      # Invalid context gets blocked by core hook before plugin runs
      assert {:block, :hook_blocked, _} = HookManager.execute_pre(combined, %{valid?: false})
    end

    test "pre and post hooks with full lifecycle" do
      reg =
        HookManager.new()
        |> HookManager.register(
          build_pre_hook("auth", 100, fn ctx ->
            if Map.get(ctx, :user) == "admin" do
              {:continue, Map.put(ctx, :authorized, true)}
            else
              :block
            end
          end)
        )
        |> HookManager.register(
          build_pre_hook("log-start", 50, fn ctx ->
            {:guide, "Starting operation for #{ctx.user}", Map.put(ctx, :started, true)}
          end)
        )
        |> HookManager.register(
          build_post_hook("log-end", 10, fn ctx ->
            {:guide, "Completed operation for #{ctx.user}", Map.put(ctx, :completed, true)}
          end)
        )
        |> HookManager.register(
          build_post_hook("cleanup", 100, fn ctx ->
            {:continue, Map.put(ctx, :cleaned_up, true)}
          end)
        )

      # Pre hooks run high→low: auth(100), log-start(50)
      # Post hooks run low→high: log-end(10), cleanup(100)
      assert {:ok, pre_ctx, pre_guides} = HookManager.execute_pre(reg, %{user: "admin"})
      assert pre_ctx.authorized == true
      assert pre_ctx.started == true
      assert pre_guides == ["Starting operation for admin"]

      assert {:ok, post_ctx, post_guides} = HookManager.execute_post(reg, pre_ctx)
      assert post_ctx.completed == true
      assert post_ctx.cleaned_up == true
      assert post_guides == ["Completed operation for admin"]
    end
  end

  # ============================================================
  # Plan mode integration: Tet.PlanMode.evaluate_with_hooks/4
  # ============================================================
  # Verifies hook ordering through the plan-mode integration path.
  # Gate decisions pass through pre-hooks, gate, and post-hooks in
  # the correct priority order, composing as documented in BD-0024.
  # Intentionally decoupled: Gate.evaluate/3 is pure and tested
  # separately — these tests validate the hook→gate→hook pipeline.

  describe "plan mode integration (evaluate_with_hooks/4)" do
    test "pre-hook priority ordering is preserved through plan-mode facade" do
      import Tet.PlanMode

      {:ok, order_agent} = Agent.start_link(fn -> [] end)

      h_high =
        build_pre_hook("pm-high", 100, fn ctx ->
          Agent.update(order_agent, &(&1 ++ [:high]))
          {:continue, ctx}
        end)

      h_low =
        build_pre_hook("pm-low", 10, fn ctx ->
          Agent.update(order_agent, &(&1 ++ [:low]))
          {:continue, ctx}
        end)

      registry =
        HookManager.new() |> HookManager.register(h_low) |> HookManager.register(h_high)

      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      {:ok, decision, _ctx, _guides} =
        evaluate_with_hooks(
          read_only_contract(),
          Tet.PlanMode.Policy.default(),
          ctx,
          registry
        )

      # Pre-hooks must run high→low: [:high, :low]
      assert [:high, :low] = Agent.get(order_agent, & &1)
      assert Tet.PlanMode.guided?(decision)
      Agent.stop(order_agent)
    end

    test "pre-hook block short-circuits gate — no post-hooks run" do
      import Tet.PlanMode

      {:ok, order_agent} = Agent.start_link(fn -> [] end)

      pre_blocker =
        build_pre_hook("pm-blocker", 200, fn _ctx ->
          Agent.update(order_agent, &(&1 ++ [:pre_blocker]))
          :block
        end)

      post_never =
        build_post_hook("pm-never", 10, fn ctx ->
          Agent.update(order_agent, &(&1 ++ [:post_never]))
          {:continue, ctx}
        end)

      registry =
        HookManager.new()
        |> HookManager.register(pre_blocker)
        |> HookManager.register(post_never)

      ctx = %{mode: :execute, task_category: :acting, task_id: "t1"}

      assert {:block, :hook_blocked, _} =
               evaluate_with_hooks(
                 write_contract(),
                 Tet.PlanMode.Policy.default(),
                 ctx,
                 registry
               )

      # Only pre-hook ran, post-hook never executed
      assert [:pre_blocker] = Agent.get(order_agent, & &1)
      Agent.stop(order_agent)
    end

    test "gate block is final — post-hooks cannot override" do
      import Tet.PlanMode

      # Post-hook tries to convert block to allow — must not run
      overrider =
        build_post_hook("pm-overrider", 10, fn ctx ->
          {:continue, Map.put(ctx, :overridden, true)}
        end)

      registry = HookManager.new() |> HookManager.register(overrider)

      # Plan mode blocks rogue write
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}
      rogue = rogue_write_contract()

      {:ok, decision, _ctx, _guides} =
        evaluate_with_hooks(
          rogue,
          Tet.PlanMode.Policy.default(),
          ctx,
          registry
        )

      assert {:block, :plan_mode_blocks_mutation} = decision
    end

    test "empty registry preserves gate behavior end-to-end" do
      import Tet.PlanMode

      registry = HookManager.new()

      # Allowed: read-only in plan/researching with guidance
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      {:ok, decision, _ctx, []} =
        evaluate_with_hooks(
          read_only_contract(),
          Tet.PlanMode.Policy.default(),
          ctx,
          registry
        )

      assert guided?(decision)

      # Blocked: write in plan/researching
      {:ok, decision, _ctx, []} =
        evaluate_with_hooks(
          write_contract(),
          Tet.PlanMode.Policy.default(),
          ctx,
          registry
        )

      assert blocked?(decision)
    end

    test "post-hook enrichment accumulates with gate guidance" do
      import Tet.PlanMode

      guide_hook =
        build_post_hook("pm-guide", 10, fn ctx ->
          {:guide, "Safety check passed", Map.put(ctx, :safety_checked, true)}
        end)

      registry = HookManager.new() |> HookManager.register(guide_hook)
      ctx = %{mode: :plan, task_category: :researching, task_id: "t1"}

      {:ok, decision, final_ctx, guides} =
        evaluate_with_hooks(
          read_only_contract(),
          Tet.PlanMode.Policy.default(),
          ctx,
          registry
        )

      assert guided?(decision)
      assert final_ctx.safety_checked == true
      assert "Safety check passed" in guides
    end
  end

  # -- Test helpers --

  defp build_pre_hook(id, priority, action_fn \\ nil) do
    fn_ = action_fn || fn ctx -> {:continue, ctx} end

    Hook.new!(%{
      id: id,
      event_type: :pre,
      priority: priority,
      action_fn: fn_
    })
  end

  defp build_post_hook(id, priority, action_fn \\ nil) do
    fn_ = action_fn || fn ctx -> {:continue, ctx} end

    Hook.new!(%{
      id: id,
      event_type: :post,
      priority: priority,
      action_fn: fn_
    })
  end

  # -- Contract fixtures for plan-mode integration tests --

  defp read_only_contract do
    {:ok, c} = ReadOnlyContracts.fetch("read")
    c
  end

  defp write_contract do
    %Contract{} = base = read_only_contract()

    %{
      base
      | name: "write-file",
        read_only: false,
        mutation: :write,
        modes: [:execute, :repair],
        task_categories: [:acting, :verifying, :debugging],
        execution: %{
          base.execution
          | mutates_workspace: true,
            executes_code: false,
            status: :contract_only,
            effects: [:writes_file]
        }
    }
  end

  defp rogue_write_contract do
    %Contract{} = base = read_only_contract()

    %{
      base
      | name: "rogue-plan-write",
        read_only: false,
        mutation: :write,
        modes: [:plan, :explore, :execute],
        task_categories: [:acting, :verifying, :debugging],
        execution: %{
          base.execution
          | mutates_workspace: true,
            executes_code: false,
            status: :contract_only,
            effects: [:writes_file]
        }
    }
  end
end
