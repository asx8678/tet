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

  Applies both policy evaluation and task-context enforcement: even if the
  policy allows a category, the task context may still require approval
  (e.g., `:write` is not safe in a `:researching` task regardless of policy).

  ## Examples

      iex> policy = Tet.Mcp.CallPolicy.default()
      iex> Tet.Mcp.PermissionGate.check(:read, %{task_category: :researching}, policy)
      {:ok, :allow}

      iex> policy = Tet.Mcp.CallPolicy.default()
      iex> Tet.Mcp.PermissionGate.check(:shell, %{task_category: :acting}, policy)
      {:ok, {:needs_approval, :policy_requires_approval}}
  """
  @spec check(category(), task_context(), CallPolicy.t()) :: {:ok, decision()}
  def check(category, task_context, %CallPolicy{} = policy) do
    {:ok, decision} = CallPolicy.evaluate(category, policy)
    enforce_and_return(decision, category, task_context)
  end

  defp enforce_and_return(:allow, category, task_context) do
    if safe_for_task?(category, task_context) do
      {:ok, :allow}
    else
      {:ok, {:needs_approval, :task_context_restriction}}
    end
  end

  defp enforce_and_return(decision, _category, _task_context) do
    {:ok, decision}
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
  Checks whether a classification category is safe for a given task context
  without consulting the full policy. Useful for quick pre-flight checks.

  Shell and admin are *never* safe without explicit approval, regardless of task.
  Network is only safe in `:acting` tasks.
  Write is only safe in `:acting` or `:debugging` tasks.

  ## Examples

      iex> Tet.Mcp.PermissionGate.safe_for_task?(:read, %{task_category: :researching})
      true

      iex> Tet.Mcp.PermissionGate.safe_for_task?(:shell, %{task_category: :acting})
      false

      iex> Tet.Mcp.PermissionGate.safe_for_task?(:network, %{task_category: :acting})
      true

      iex> Tet.Mcp.PermissionGate.safe_for_task?(:network, %{task_category: :debugging})
      false
  """
  @spec safe_for_task?(category(), task_context()) :: boolean()
  def safe_for_task?(:read, _task_context), do: true
  def safe_for_task?(:write, %{task_category: cat}) when cat in [:acting, :debugging], do: true
  def safe_for_task?(:write, _), do: false
  def safe_for_task?(:network, %{task_category: :acting}), do: true
  def safe_for_task?(:network, _), do: false
  def safe_for_task?(:shell, _), do: false
  def safe_for_task?(:admin, _), do: false
end
