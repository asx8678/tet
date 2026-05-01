defmodule Tet.HookManager do
  @moduledoc """
  Priority-ordered hook execution with deterministic ordering and composable
  actions.

  BD-0024 defines the hook lifecycle: pre-hooks execute in descending priority
  order (highest first), post-hooks execute in ascending priority order (lowest
  first). Each hook returns an action — `:continue`, `:block`, `{:modify,
  context}`, or `{:guide, message, context}` — and execution short-circuits on
  the first block.

  ## Registry

  A registry is a simple map with `:pre_hooks` and `:post_hooks` lists. This
  module provides pure functions to create, register, deregister, and execute
  hooks without side effects.

  ## Execution model

  1. Select hooks matching the event type
  2. Sort by priority (pre: descending, post: ascending)
  3. Iterate deterministically, threading context through `{:continue, ctx}` /
     `{:modify, ctx}` / `{:guide, msg, ctx}` results
  4. Short-circuit on first `:block`, returning `{:block, reason, context}`
  5. On success, return `{:ok, final_context, guides}`

  ## Examples

      iex> hm = Tet.HookManager
      iex> registry = hm.new()
      iex> hook1 = Tet.HookManager.Hook.new!(%{id: "h1", event_type: :pre, priority: 100,
      ...>   action_fn: fn ctx -> {:continue, Map.put(ctx, :a, 1)} end})
      iex> hook2 = Tet.HookManager.Hook.new!(%{id: "h2", event_type: :pre, priority: 50,
      ...>   action_fn: fn ctx -> {:guide, "hello", Map.put(ctx, :b, 2)} end})
      iex> registry = hm.register(registry, hook1) |> hm.register(hook2)
      iex> {:ok, ctx, guides} = hm.execute_pre(registry, %{})
      iex> ctx
      %{a: 1, b: 2}
      iex> guides
      ["hello"]

      iex> # Block short-circuits
      iex> blocker = Tet.HookManager.Hook.new!(%{id: "b1", event_type: :pre, priority: 200,
      ...>   action_fn: fn _ctx -> :block end})
      iex> registry = hm.register(hm.new(), blocker)
      iex> hm.execute_pre(registry, %{})
      {:block, :hook_blocked, %{}}

  ## Composability

  Registries can be merged (composed) by concatenating hook lists. This lets
  different layers (core, runtime, plugins) register their own hooks without
  conflicts — ids should be unique across layers.

      iex> r1 = Tet.HookManager.new() |> Tet.HookManager.register(
      ...>   Tet.HookManager.Hook.new!(%{id: "core", event_type: :pre, priority: 0,
      ...>     action_fn: fn ctx -> {:continue, ctx} end}))
      iex> r2 = Tet.HookManager.new() |> Tet.HookManager.register(
      ...>   Tet.HookManager.Hook.new!(%{id: "plugin", event_type: :pre, priority: 10,
      ...>     action_fn: fn ctx -> {:continue, ctx} end}))
      iex> merged = Tet.HookManager.merge(r1, r2)
      iex> length(merged.pre_hooks)
      2
  """

  alias Tet.HookManager.Hook

  @type action :: Hook.action()
  @type execution_result :: {:ok, map(), [binary()]} | {:block, term(), map()}
  @type registry :: %{required(:pre_hooks) => [Hook.t()], required(:post_hooks) => [Hook.t()]}

  @doc """
  Returns an empty hook registry.

  A registry is a map with `:pre_hooks` and `:post_hooks` lists, both empty.
  """
  @spec new() :: registry()
  def new, do: %{pre_hooks: [], post_hooks: []}

  @doc """
  Registers a hook into the registry.

  Hooks are appended to the appropriate list. Tie-breaking for equal-priority
  hooks uses registration order (first registered = first executed within the
  same priority tier).

  ## Examples

      iex> hook = Tet.HookManager.Hook.new!(%{id: "test", event_type: :pre, priority: 0,
      ...>   action_fn: fn ctx -> {:continue, ctx} end})
      iex> reg = Tet.HookManager.new() |> Tet.HookManager.register(hook)
      iex> length(reg.pre_hooks)
      1

  Duplicate ids are silently replaced (last-write-wins).
  """
  @spec register(registry(), Hook.t()) :: registry()
  def register(registry, %Hook{event_type: :pre} = hook) do
    %{registry | pre_hooks: replace_or_append(registry.pre_hooks, hook)}
  end

  def register(registry, %Hook{event_type: :post} = hook) do
    %{registry | post_hooks: replace_or_append(registry.post_hooks, hook)}
  end

  @doc """
  Removes a hook from the registry by id.

  Returns the updated registry. If no hook with the given id exists, the
  registry is returned unchanged.

  ## Examples

      iex> hook = Tet.HookManager.Hook.new!(%{id: "gone", event_type: :pre, priority: 0,
      ...>   action_fn: fn ctx -> {:continue, ctx} end})
      iex> reg = Tet.HookManager.new() |> Tet.HookManager.register(hook)
      iex> reg = Tet.HookManager.deregister(reg, "gone")
      iex> reg.pre_hooks
      []
  """
  @spec deregister(registry(), binary()) :: registry()
  def deregister(registry, hook_id) when is_binary(hook_id) do
    %{
      registry
      | pre_hooks: Enum.reject(registry.pre_hooks, &(&1.id == hook_id)),
        post_hooks: Enum.reject(registry.post_hooks, &(&1.id == hook_id))
    }
  end

  @doc """
  Executes pre-hooks in descending priority order (high → low).

  Each hook's action function receives the current context map. Hooks can:
    - `{:continue, context}` — pass modified context to the next hook
    - `{:modify, context}` — same as continue (readability alias)
    - `{:guide, message, context}` — allow with guidance, accumulate message
    - `:block` — veto immediately, return `{:block, :hook_blocked, context}`

  Returns `{:ok, final_context, guide_messages}` on success, or
  `{:block, reason, context_at_block}` on first block.
  """
  @spec execute_pre(registry(), map()) :: execution_result()
  def execute_pre(registry, context) when is_map(context) do
    registry.pre_hooks
    |> sort_descending()
    |> execute_hooks(context, [])
  end

  @doc """
  Executes post-hooks in ascending priority order (low → high).

  Same semantics as `execute_pre/2` but sorted low-to-high so lower-priority
  hooks (e.g., logging, audit) run first and higher-priority hooks
  (e.g., finalizers) run last.
  """
  @spec execute_post(registry(), map()) :: execution_result()
  def execute_post(registry, context) when is_map(context) do
    registry.post_hooks
    |> sort_ascending()
    |> execute_hooks(context, [])
  end

  @doc """
  Merges two registries by concatenating their hook lists.

  The first registry's hooks come first in each list. Duplicate ids are NOT
  deduplicated — use `register/2` for idempotent registration or call
  `deregister/2` first.
  """
  @spec merge(registry(), registry()) :: registry()
  def merge(registry1, registry2) do
    %{
      pre_hooks: registry1.pre_hooks ++ registry2.pre_hooks,
      post_hooks: registry1.post_hooks ++ registry2.post_hooks
    }
  end

  @doc """
  Returns all hook ids in the registry, grouped by event type.

  ## Examples

      iex> reg = Tet.HookManager.new()
      iex> Tet.HookManager.hook_ids(reg)
      %{pre: [], post: []}
  """
  @spec hook_ids(registry()) :: %{pre: [binary()], post: [binary()]}
  def hook_ids(registry) do
    %{
      pre: Enum.map(registry.pre_hooks, & &1.id),
      post: Enum.map(registry.post_hooks, & &1.id)
    }
  end

  @doc """
  Returns the count of hooks by event type.

  ## Examples

      iex> Tet.HookManager.count(Tet.HookManager.new())
      %{pre: 0, post: 0}
  """
  @spec count(registry()) :: %{pre: non_neg_integer(), post: non_neg_integer()}
  def count(registry) do
    %{pre: length(registry.pre_hooks), post: length(registry.post_hooks)}
  end

  # -- Private helpers --

  defp replace_or_append(hooks, %Hook{id: id} = new_hook) do
    if Enum.any?(hooks, &(&1.id == id)) do
      Enum.map(hooks, fn
        %Hook{id: ^id} -> new_hook
        other -> other
      end)
    else
      hooks ++ [new_hook]
    end
  end

  defp sort_descending(hooks), do: Enum.sort_by(hooks, & &1.priority, :desc)
  defp sort_ascending(hooks), do: Enum.sort_by(hooks, & &1.priority, :asc)

  defp execute_hooks([], context, guides), do: {:ok, context, Enum.reverse(guides)}

  defp execute_hooks([%Hook{action_fn: action_fn} | rest], context, guides) do
    case action_fn.(context) do
      :block ->
        {:block, :hook_blocked, context}

      {:continue, new_ctx} when is_map(new_ctx) ->
        execute_hooks(rest, new_ctx, guides)

      {:modify, new_ctx} when is_map(new_ctx) ->
        execute_hooks(rest, new_ctx, guides)

      {:guide, message, new_ctx} when is_binary(message) and is_map(new_ctx) ->
        execute_hooks(rest, new_ctx, [message | guides])

      _invalid ->
        {:block, :invalid_hook_action, context}
    end
  end
end
