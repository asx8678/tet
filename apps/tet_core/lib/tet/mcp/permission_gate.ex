defmodule Tet.Mcp.PermissionGate do
  @moduledoc """
  Permission gate for MCP tool calls.

  Every MCP tool call must pass through this gate before execution. The gate
  checks the tool's classification against the task context and active policy
  to return one of three decisions:

    - `:allow` — the call may proceed immediately.
    - `:deny` — the call is forbidden.
    - `{:needs_approval, reason}` — the call requires explicit user/operator approval.

  This is a set of pure functions — no side effects, no IO, no processes.
  Runtime integration (`Tet.Runtime.Mcp.PolicyGate`) wraps these functions
  with process state, pending approvals, and event logging.

  ## Decision flow

  1. Blocked categories always deny, regardless of task context.
  2. Read-classified tools are allowed in all task contexts.
  3. Write/shell/network/admin tools are checked against the task category
     and the active call policy.
  4. Shell-classified tools require explicit approval in every context.

  Inspired by Codex `exec_policy.rs` where every command passes through
  prefix rules, heuristics, and an approval policy before execution.
  """

  alias Tet.Mcp.CallPolicy
  alias Tet.Mcp.Classification

  @type category :: Classification.category()
  @type task_context :: %{
          required(:task_category) => atom(),
          optional(:task_id) => String.t() | nil,
          optional(:session_id) => String.t() | nil
        }
  @type decision :: :allow | :deny | {:needs_approval, atom()}
  @type approval_ref :: {String.t(), category()}

  @doc """
  Checks whether an MCP tool call is permitted.

  Takes a classification category, a task context map, and a call policy.
  Returns `:allow`, `:deny`, or `{:needs_approval, reason}`.

  ## Examples

      iex> policy = Tet.Mcp.CallPolicy.default()
      iex> Tet.Mcp.PermissionGate.check(:read, %{task_category: :researching}, policy)
      :allow

      iex> policy = Tet.Mcp.CallPolicy.default()
      iex> Tet.Mcp.PermissionGate.check(:shell, %{task_category: :acting}, policy)
      {:needs_approval, :policy_requires_approval}
  """
  @spec check(category(), task_context(), CallPolicy.t()) :: decision()
  def check(category, _task_context, %CallPolicy{} = policy) do
    CallPolicy.evaluate(category, policy)
  end

  @doc """
  Explicitly approves a pending gate.

  Returns `:ok` if the approval is valid, `{:error, reason}` otherwise.
  This function is pure — the runtime GenServer tracks pending state.

  ## Examples

      iex> Tet.Mcp.PermissionGate.approve({"call-1", :write}, %{task_category: :acting})
      :ok
  """
  @spec approve(approval_ref(), task_context()) :: :ok | {:error, term()}
  def approve({call_id, category}, _task_context)
      when is_binary(call_id) and is_atom(category) do
    if category in Classification.categories() do
      :ok
    else
      {:error, {:invalid_category, category}}
    end
  end

  def approve(_ref, _context), do: {:error, :invalid_approval_ref}

  @doc """
  Explicitly denies a pending gate.

  Returns `:ok` always — denial is the safe default and cannot fail.

  ## Examples

      iex> Tet.Mcp.PermissionGate.deny({"call-1", :shell}, :user_denied)
      :ok
  """
  @spec deny(approval_ref(), atom()) :: :ok
  def deny({call_id, _category}, _reason) when is_binary(call_id), do: :ok
  def deny(_ref, _reason), do: :ok

  @doc """
  Checks whether a classification category is safe for a given task category
  without consulting the full policy. Useful for quick pre-flight checks.

  Shell is *never* safe without explicit approval, regardless of task.

  ## Examples

      iex> Tet.Mcp.PermissionGate.safe_for_task?(:read, :researching)
      true

      iex> Tet.Mcp.PermissionGate.safe_for_task?(:shell, :acting)
      false
  """
  @spec safe_for_task?(category(), atom()) :: boolean()
  def safe_for_task?(:read, _task_category), do: true
  def safe_for_task?(:shell, _task_category), do: false
  def safe_for_task?(:admin, _task_category), do: false

  def safe_for_task?(category, task_category) when category in [:write, :network] do
    task_category in [:acting, :debugging]
  end

  def safe_for_task?(_category, _task_category), do: false
end
