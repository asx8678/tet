defmodule Tet.Runtime.Mcp.PolicyGate do
  @moduledoc """
  Runtime GenServer wrapping MCP permission checks.

  This is the authoritative gate every MCP call must pass through before
  execution. It wraps the pure functions in `Tet.Mcp.PermissionGate` with
  process state for:
    - Pending approvals (calls awaiting explicit user/operator approval).
    - Event logging for audit trail.
    - Policy resolution from task context.

  ## Architecture

  The pure gate modules (`Classification`, `CallPolicy`, `PermissionGate`)
  are deterministic, side-effect-free functions. This GenServer adds:
    - Stateful pending-approval tracking.
    - Event publication via `Tet.EventBus`.
    - Thread-safe policy evaluation under concurrent call pressure.

  Inspired by Codex `ExecPolicyManager` which wraps a `Policy` in an
  `ArcSwap` for concurrent reads and a `Semaphore` for serialized updates.
  """

  use GenServer

  alias Tet.Mcp.CallPolicy
  alias Tet.Mcp.Classification
  alias Tet.Mcp.PermissionGate

  @type pending_approval :: %{
          call_id: String.t(),
          tool_name: String.t(),
          category: Classification.category(),
          task_context: PermissionGate.task_context(),
          inserted_at: DateTime.t()
        }

  @type state :: %{
          policy: CallPolicy.t(),
          pending: %{String.t() => pending_approval()},
          decisions: [map()]
        }

  # -- Client API --

  @doc "Starts the policy gate GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Authoritative check before an MCP tool call.

  Classifies the tool, evaluates the policy, and either allows, denies, or
  marks the call as pending approval. Returns the decision plus a `call_id`
  for tracking.

  ## Returns

    - `{:allow, call_id}` — proceed immediately.
    - `{:deny, call_id, reason}` — call is forbidden.
    - `{:needs_approval, call_id, reason}` — call is queued for approval.
  """
  @spec authorize_call(map(), PermissionGate.task_context(), keyword()) ::
          {:allow, String.t()}
          | {:deny, String.t(), atom()}
          | {:needs_approval, String.t(), atom()}
  def authorize_call(tool_descriptor, task_context, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_id = generate_call_id()
    category = Classification.classify(tool_descriptor)

    GenServer.call(server, {:authorize, call_id, tool_descriptor, category, task_context})
  end

  @doc "Approves a pending call by its call_id."
  @spec approve_call(String.t(), keyword()) :: :ok | {:error, term()}
  def approve_call(call_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:approve, call_id})
  end

  @doc "Denies a pending call by its call_id."
  @spec deny_call(String.t(), keyword()) :: :ok | {:error, term()}
  def deny_call(call_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:deny, call_id})
  end

  @doc "Logs a policy decision to the event log for audit."
  @spec log_decision(atom(), map()) :: :ok
  def log_decision(decision, metadata) do
    if Tet.EventBus.started?() do
      Tet.EventBus.publish("mcp.policy", %{
        decision: decision,
        metadata: metadata,
        logged_at: DateTime.utc_now()
      })
    end

    :ok
  end

  @doc "Returns the current call policy."
  @spec get_policy(keyword()) :: CallPolicy.t()
  def get_policy(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :get_policy)
  end

  @doc "Updates the call policy at runtime."
  @spec update_policy(CallPolicy.t(), keyword()) :: :ok
  def update_policy(%CallPolicy{} = policy, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:update_policy, policy})
  end

  @doc "Returns all pending approvals."
  @spec list_pending(keyword()) :: [pending_approval()]
  def list_pending(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :list_pending)
  end

  # -- GenServer callbacks --

  @impl GenServer
  def init(opts) do
    policy =
      case Keyword.get(opts, :policy) do
        %CallPolicy{} = p -> p
        _ -> CallPolicy.default()
      end

    {:ok, %{policy: policy, pending: %{}, decisions: []}}
  end

  @impl GenServer
  def handle_call({:authorize, call_id, tool_descriptor, category, task_context}, _from, state) do
    {:ok, decision} = PermissionGate.check(category, task_context, state.policy)
    tool_name = Map.get(tool_descriptor, :name, "unknown")

    # Record decision for audit
    record = %{
      call_id: call_id,
      tool_name: tool_name,
      category: category,
      decision: decision,
      task_context: task_context,
      decided_at: DateTime.utc_now()
    }

    log_decision(decision, record)

    case decision do
      :allow ->
        {:reply, {:allow, call_id}, append_decision(state, record)}

      :deny ->
        {:reply, {:deny, call_id, :blocked_by_policy}, append_decision(state, record)}

      {:needs_approval, reason} ->
        pending_entry = %{
          call_id: call_id,
          tool_name: tool_name,
          category: category,
          task_context: task_context,
          inserted_at: DateTime.utc_now()
        }

        new_pending = Map.put(state.pending, call_id, pending_entry)

        {:reply, {:needs_approval, call_id, reason},
         append_decision(%{state | pending: new_pending}, record)}
    end
  end

  def handle_call({:approve, call_id}, _from, state) do
    case Map.pop(state.pending, call_id) do
      {nil, _pending} ->
        {:reply, {:error, :not_found}, state}

      {approval, new_pending} ->
        record = %{
          call_id: call_id,
          tool_name: approval.tool_name,
          category: approval.category,
          decision: :approved,
          task_context: approval.task_context,
          decided_at: DateTime.utc_now()
        }

        log_decision(:approved, record)
        {:reply, :ok, append_decision(%{state | pending: new_pending}, record)}
    end
  end

  def handle_call({:deny, call_id}, _from, state) do
    case Map.pop(state.pending, call_id) do
      {nil, _pending} ->
        {:reply, {:error, :not_found}, state}

      {approval, new_pending} ->
        record = %{
          call_id: call_id,
          tool_name: approval.tool_name,
          category: approval.category,
          decision: :denied,
          task_context: approval.task_context,
          decided_at: DateTime.utc_now()
        }

        log_decision(:denied, record)
        {:reply, :ok, append_decision(%{state | pending: new_pending}, record)}
    end
  end

  def handle_call(:get_policy, _from, state) do
    {:reply, state.policy, state}
  end

  def handle_call({:update_policy, policy}, _from, state) do
    {:reply, :ok, %{state | policy: policy}}
  end

  def handle_call(:list_pending, _from, state) do
    {:reply, Map.values(state.pending), state}
  end

  # -- Private --

  defp generate_call_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end

  defp append_decision(state, record) do
    # Keep bounded decision history (last 256 decisions)
    decisions = [record | state.decisions] |> Enum.take(256)
    %{state | decisions: decisions}
  end
end
