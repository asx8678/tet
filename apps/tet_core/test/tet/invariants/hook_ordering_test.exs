defmodule Tet.Invariants.HookOrderingTest do
  @moduledoc """
  BD-0026 — Invariant 3: Priority-ordered hook execution.

  Verifies that:
  - Pre-hooks execute in descending priority order (high → low)
  - Post-hooks execute in ascending priority order (low → high)
  - Equal-priority hooks execute in registration order (deterministic tie-breaking)
  - Block actions short-circuit remaining hooks
  - Hook system composes with gate evaluation for full lifecycle
  """

  use ExUnit.Case, async: true

  alias Tet.HookManager
  alias Tet.HookManager.Hook

  # ============================================================
  # Invariant 3a: Pre-hooks execute high → low
  # ============================================================

  describe "pre-hooks execute in descending priority (high → low)" do
    test "three hooks with different priorities execute high-first" do
      h_low =
        pre_hook("low", 10, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:low])}
        end)

      h_mid =
        pre_hook("mid", 50, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:mid])}
        end)

      h_high =
        pre_hook("high", 100, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:high])}
        end)

      reg =
        HookManager.new()
        |> HookManager.register(h_low)
        |> HookManager.register(h_high)
        |> HookManager.register(h_mid)

      {:ok, ctx, _guides} = HookManager.execute_pre(reg, %{})
      assert ctx.order == [:high, :mid, :low]
    end

    test "five hooks execute in correct descending order" do
      priorities = [10, 200, 50, 300, 150]
      ids = for p <- priorities, do: "h#{p}"

      hooks =
        for {id, p} <- Enum.zip(ids, priorities) do
          pre_hook(id, p, fn ctx ->
            {:continue,
             Map.put(
               ctx,
               :order,
               Map.get(ctx, :order, []) ++ [String.to_integer(String.trim_leading(id, "h"))]
             )}
          end)
        end

      reg = Enum.reduce(hooks, HookManager.new(), &HookManager.register(&2, &1))
      {:ok, ctx, _} = HookManager.execute_pre(reg, %{})
      assert ctx.order == [300, 200, 150, 50, 10]
    end

    test "single pre-hook executes and passes context" do
      hook = pre_hook("solo", 42, fn ctx -> {:continue, Map.put(ctx, :ran, true)} end)
      reg = HookManager.new() |> HookManager.register(hook)
      {:ok, ctx, _} = HookManager.execute_pre(reg, %{})
      assert ctx.ran == true
    end
  end

  # ============================================================
  # Invariant 3b: Post-hooks execute low → high
  # ============================================================

  describe "post-hooks execute in ascending priority (low → high)" do
    test "three hooks with different priorities execute low-first" do
      h_low =
        post_hook("low", 10, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:low])}
        end)

      h_mid =
        post_hook("mid", 50, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:mid])}
        end)

      h_high =
        post_hook("high", 100, fn ctx ->
          {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [:high])}
        end)

      reg =
        HookManager.new()
        |> HookManager.register(h_high)
        |> HookManager.register(h_low)
        |> HookManager.register(h_mid)

      {:ok, ctx, _} = HookManager.execute_post(reg, %{})
      assert ctx.order == [:low, :mid, :high]
    end

    test "five post-hooks execute in ascending order" do
      priorities = [10, 200, 50, 300, 150]

      hooks =
        for p <- priorities do
          post_hook("p#{p}", p, fn ctx ->
            {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [p])}
          end)
        end

      reg = Enum.reduce(hooks, HookManager.new(), &HookManager.register(&2, &1))
      {:ok, ctx, _} = HookManager.execute_post(reg, %{})
      assert ctx.order == [10, 50, 150, 200, 300]
    end
  end

  # ============================================================
  # Invariant 3c: Equal-priority tie-breaking (registration order)
  # ============================================================

  describe "equal-priority hooks use registration order for tie-breaking" do
    test "pre-hooks with same priority execute in registration order" do
      hooks =
        for i <- 1..5 do
          pre_hook("eq#{i}", 0, fn ctx ->
            {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [i])}
          end)
        end

      reg = Enum.reduce(hooks, HookManager.new(), &HookManager.register(&2, &1))
      {:ok, ctx, _} = HookManager.execute_pre(reg, %{})
      assert ctx.order == [1, 2, 3, 4, 5]
    end

    test "post-hooks with same priority execute in registration order" do
      hooks =
        for i <- 1..4 do
          post_hook("eq#{i}", 100, fn ctx ->
            {:continue, Map.put(ctx, :order, Map.get(ctx, :order, []) ++ [i])}
          end)
        end

      reg = Enum.reduce(hooks, HookManager.new(), &HookManager.register(&2, &1))
      {:ok, ctx, _} = HookManager.execute_post(reg, %{})
      assert ctx.order == [1, 2, 3, 4]
    end
  end

  # ============================================================
  # Invariant 3d: Block short-circuits remaining hooks
  # ============================================================

  describe "block action short-circuits remaining hooks" do
    test "pre-hook block prevents later hooks from running" do
      h_blocker = pre_hook("blocker", 200, fn _ctx -> :block end)

      h_never =
        pre_hook("never", 100, fn ctx ->
          {:continue, Map.put(ctx, :ran_never, true)}
        end)

      reg = HookManager.new() |> HookManager.register(h_blocker) |> HookManager.register(h_never)
      assert {:block, :hook_blocked, _ctx} = HookManager.execute_pre(reg, %{})
    end

    test "post-hook block prevents later hooks from running" do
      h_blocker = post_hook("blocker", 10, fn _ctx -> :block end)

      h_never =
        post_hook("never", 100, fn ctx ->
          {:continue, Map.put(ctx, :ran_never, true)}
        end)

      reg = HookManager.new() |> HookManager.register(h_blocker) |> HookManager.register(h_never)
      assert {:block, :hook_blocked, _ctx} = HookManager.execute_post(reg, %{})
    end

    test "mid-priority block stops the chain but earlier hooks already ran" do
      h_high = pre_hook("high", 100, fn ctx -> {:continue, Map.put(ctx, :high_ran, true)} end)
      h_blocker = pre_hook("blocker", 50, fn _ctx -> :block end)
      h_low = pre_hook("low", 10, fn ctx -> {:continue, Map.put(ctx, :low_ran, true)} end)

      reg =
        HookManager.new()
        |> HookManager.register(h_high)
        |> HookManager.register(h_blocker)
        |> HookManager.register(h_low)

      assert {:block, :hook_blocked, ctx} = HookManager.execute_pre(reg, %{})
      assert ctx.high_ran == true
      refute Map.has_key?(ctx, :low_ran)
    end
  end

  # ============================================================
  # Invariant 3e: Mixed actions compose correctly
  # ============================================================

  describe "mixed actions compose correctly through the hook chain" do
    test "modify → guide → continue produces correct final context and guides" do
      h_mod = pre_hook("mod", 300, fn ctx -> {:modify, Map.put(ctx, :step1, true)} end)

      h_guide =
        pre_hook("guide", 200, fn ctx ->
          {:guide, "step two guidance", Map.put(ctx, :step2, true)}
        end)

      h_cont = pre_hook("cont", 100, fn ctx -> {:continue, Map.put(ctx, :step3, true)} end)

      reg =
        HookManager.new()
        |> HookManager.register(h_mod)
        |> HookManager.register(h_guide)
        |> HookManager.register(h_cont)

      {:ok, ctx, guides} = HookManager.execute_pre(reg, %{})
      assert ctx.step1 == true
      assert ctx.step2 == true
      assert ctx.step3 == true
      assert guides == ["step two guidance"]
    end

    test "guide messages accumulate in hook execution order" do
      h1 = pre_hook("g1", 100, fn ctx -> {:guide, "first", ctx} end)
      h2 = pre_hook("g2", 50, fn ctx -> {:guide, "second", ctx} end)
      h3 = pre_hook("g3", 10, fn ctx -> {:guide, "third", ctx} end)

      reg =
        HookManager.new()
        |> HookManager.register(h3)
        |> HookManager.register(h1)
        |> HookManager.register(h2)

      {:ok, _ctx, guides} = HookManager.execute_pre(reg, %{})
      # Pre-hooks run high→low, so guidance order is first, second, third
      assert guides == ["first", "second", "third"]
    end
  end

  # ============================================================
  # Invariant 3f: Full lifecycle with pre and post hooks
  # ============================================================

  describe "full pre+post lifecycle" do
    test "pre high→low then post low→high produces correct combined order" do
      h_pre_high =
        pre_hook("pre-high", 100, fn ctx ->
          {:continue, Map.put(ctx, :trace, Map.get(ctx, :trace, []) ++ [:pre_high])}
        end)

      h_pre_low =
        pre_hook("pre-low", 10, fn ctx ->
          {:continue, Map.put(ctx, :trace, Map.get(ctx, :trace, []) ++ [:pre_low])}
        end)

      h_post_low =
        post_hook("post-low", 10, fn ctx ->
          {:continue, Map.put(ctx, :trace, Map.get(ctx, :trace, []) ++ [:post_low])}
        end)

      h_post_high =
        post_hook("post-high", 100, fn ctx ->
          {:continue, Map.put(ctx, :trace, Map.get(ctx, :trace, []) ++ [:post_high])}
        end)

      reg =
        HookManager.new()
        |> HookManager.register(h_pre_low)
        |> HookManager.register(h_pre_high)
        |> HookManager.register(h_post_high)
        |> HookManager.register(h_post_low)

      {:ok, pre_ctx, _pre_guides} = HookManager.execute_pre(reg, %{})
      assert pre_ctx.trace == [:pre_high, :pre_low]

      {:ok, post_ctx, _post_guides} = HookManager.execute_post(reg, pre_ctx)
      assert post_ctx.trace == [:pre_high, :pre_low, :post_low, :post_high]
    end
  end

  # ============================================================
  # Invariant 3g: Invalid hook actions fail closed
  # ============================================================

  describe "invalid hook actions fail closed" do
    test "invalid action (atom) returns :block" do
      hook = pre_hook("bad", 100, fn _ctx -> :invalid_atom end)
      reg = HookManager.new() |> HookManager.register(hook)
      assert {:block, :invalid_hook_action, _} = HookManager.execute_pre(reg, %{})
    end

    test "invalid action (tuple with wrong shape) returns :block" do
      hook = pre_hook("bad-tuple", 100, fn _ctx -> {:wrong, %{}} end)
      reg = HookManager.new() |> HookManager.register(hook)
      assert {:block, :invalid_hook_action, _} = HookManager.execute_pre(reg, %{})
    end
  end

  # -- Helpers --

  defp pre_hook(id, priority, action_fn) do
    Hook.new!(%{
      id: id,
      event_type: :pre,
      priority: priority,
      action_fn: action_fn
    })
  end

  defp post_hook(id, priority, action_fn) do
    Hook.new!(%{
      id: id,
      event_type: :post,
      priority: priority,
      action_fn: action_fn
    })
  end
end
