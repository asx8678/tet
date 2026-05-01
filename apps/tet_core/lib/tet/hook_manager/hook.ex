defmodule Tet.HookManager.Hook do
  @moduledoc """
  A registered hook with priority, event type, and action function.

  Hooks are the atoms of the hook system — each one carries an `event_type`
  (`:pre` or `:post`), a numeric `priority`, and an `action_fn` that receives
  the current context map and returns one of:

    - `{:continue, context}` — allow execution to proceed, optionally with a
      modified context.
    - `:block` — veto the operation entirely.
    - `{:modify, context}` — transform the context and continue (alias for
      `{:continue, context}` for readability in mutation hooks).
    - `{:guide, message, context}` — allow execution but attach a guidance
      message for downstream consumers.

  ## Priorities

  Priorities are integers. Higher values = higher priority. Pre-hooks execute
  in descending order (high → low), post-hooks in ascending order (low → high).
  Equal-priority hooks execute in registration order for deterministic
  tie-breaking.

  ## Examples

      iex> hook = Tet.HookManager.Hook.new!(%{
      ...>   id: "audit-1",
      ...>   event_type: :pre,
      ...>   priority: 100,
      ...>   action_fn: fn ctx -> {:continue, ctx} end,
      ...>   description: "Audit log pre-hook"
      ...> })
      ...> hook.id
      "audit-1"

      iex> Tet.HookManager.Hook.block_hook?({:continue, %{}})
      false

      iex> Tet.HookManager.Hook.block_hook?(:block)
      true
  """

  @action_types [:continue, :block, :modify, :guide]

  @enforce_keys [:id, :event_type, :priority, :action_fn]
  defstruct [:id, :event_type, :priority, :action_fn, :description]

  @type action_fn :: (map() -> action())
  @type action :: {:continue, map()} | :block | {:modify, map()} | {:guide, String.t(), map()}

  @type t :: %__MODULE__{
          id: binary(),
          event_type: :pre | :post,
          priority: integer(),
          action_fn: action_fn(),
          description: binary() | nil
        }

  @doc "Returns the known action types."
  @spec action_types() :: [atom()]
  def action_types, do: @action_types

  @doc """
  Builds a validated hook from raw attrs (atom or string keys).

  ## Options

    * `:id` — unique hook identifier (required, non-empty binary)
    * `:event_type` — `:pre` or `:post` (required)
    * `:priority` — integer priority (required)
    * `:action_fn` — function of arity 1 receiving context map (required)
    * `:description` — optional human-readable description
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    id = fetch_value(attrs, :id)

    with {:ok, id} <- validate_id(id),
         {:ok, event_type} <- fetch_event_type(attrs),
         {:ok, priority} <- fetch_priority(attrs),
         {:ok, action_fn} <- fetch_action_fn(attrs) do
      description = fetch_optional_string(attrs, :description)

      {:ok,
       %__MODULE__{
         id: id,
         event_type: event_type,
         priority: priority,
         action_fn: action_fn,
         description: description
       }}
    end
  end

  @doc "Builds a hook or raises `ArgumentError`."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, hook} -> hook
      {:error, reason} -> raise ArgumentError, "invalid hook: #{inspect(reason)}"
    end
  end

  @doc "Returns true when an action indicates the operation should be blocked."
  @spec block_hook?(action()) :: boolean()
  def block_hook?(:block), do: true
  def block_hook?(_action), do: false

  @doc "Returns true when an action is a guidance message."
  @spec guide_action?(action()) :: boolean()
  def guide_action?({:guide, _message, _context}), do: true
  def guide_action?(_action), do: false

  @doc "Returns true when an action continues execution (continue, modify, or guide)."
  @spec continue_action?(action()) :: boolean()
  def continue_action?(action), do: not block_hook?(action)

  @doc "Extracts the guidance message from a guide action."
  @spec guide_message(action()) :: binary() | nil
  def guide_message({:guide, message, _context}) when is_binary(message), do: message
  def guide_message(_action), do: nil

  @doc "Extracts the context from any non-block action."
  @spec action_context(action()) :: map()
  def action_context({:continue, context}), do: context
  def action_context({:modify, context}), do: context
  def action_context({:guide, _message, context}), do: context
  def action_context(:block), do: %{}

  # -- Validators --

  defp validate_id(id) when is_binary(id) and byte_size(id) > 0, do: {:ok, id}
  defp validate_id(_), do: {:error, :invalid_hook_id}

  defp fetch_event_type(attrs) do
    case fetch_value(attrs, :event_type) do
      :pre -> {:ok, :pre}
      :post -> {:ok, :post}
      :pre_tool_use -> {:ok, :pre}
      :post_tool_use -> {:ok, :post}
      "pre" -> {:ok, :pre}
      "post" -> {:ok, :post}
      _other -> {:error, :invalid_event_type}
    end
  end

  defp fetch_priority(attrs) do
    case fetch_value(attrs, :priority) do
      priority when is_integer(priority) -> {:ok, priority}
      _other -> {:error, :invalid_priority}
    end
  end

  defp fetch_action_fn(attrs) do
    case fetch_value(attrs, :action_fn) do
      fun when is_function(fun, 1) -> {:ok, fun}
      _other -> {:error, :invalid_action_fn}
    end
  end

  defp fetch_optional_string(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp fetch_value(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end
end
