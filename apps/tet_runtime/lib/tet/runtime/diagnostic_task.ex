defmodule Tet.Runtime.DiagnosticTask do
  @moduledoc """
  Diagnostic-only debugging task context — BD-0059.

  Creates a restricted task mode that confines an agent to diagnosis only
  (reading, searching, inspecting) until a repair plan has been submitted
  and explicitly approved. Once approved, the task can be promoted to full
  repair mode, unlocking mutating tools.

  ## Status lifecycle

      :diagnosing → :plan_ready → :repair_approved → :repair_active

  Status is derived from struct state, not stored explicitly. This keeps
  the state machine honest and eliminates impossible status/field combos.

  This module is pure data and pure functions. It does not dispatch tools,
  touch the filesystem, or persist events.
  """

  @diagnostic_tools [:read, :search, :list, :doctor, :error_log_inspect]
  @diagnostic_tool_strings Enum.map(@diagnostic_tools, &Atom.to_string/1)
  @blocked_tools [:patch, :write, :shell, :deploy]

  @enforce_keys [:id, :session_id, :error_log_entry]
  defstruct [
    :id,
    :session_id,
    :error_log_entry,
    :repair_plan,
    :approval_status,
    mode: :diagnostic,
    created_at: nil,
    metadata: %{}
  ]

  @type status :: :diagnosing | :plan_ready | :repair_approved | :repair_active
  @type mode :: :diagnostic | :repair
  @type approval :: :pending | :approved | :rejected
  @type tool_name :: atom()

  @type t :: %__MODULE__{
          id: binary(),
          session_id: binary(),
          error_log_entry: Tet.ErrorLog.t(),
          repair_plan: map() | nil,
          approval_status: approval() | nil,
          mode: mode(),
          created_at: DateTime.t() | nil,
          metadata: map()
        }

  # ── Public accessors ────────────────────────────────────────────────────

  @doc "Returns tools allowed during diagnostic mode."
  @spec diagnostic_tools() :: [tool_name()]
  def diagnostic_tools, do: @diagnostic_tools

  @doc "Returns tools blocked until repair mode is active."
  @spec blocked_tools() :: [tool_name()]
  def blocked_tools, do: @blocked_tools

  # ── Construction ────────────────────────────────────────────────────────

  @doc """
  Creates a diagnostic task context from an error log entry and session id.

  The task starts in `:diagnosing` status with only diagnostic tools allowed.

  ## Examples

      iex> error = struct(Tet.ErrorLog, %{id: "err_1", session_id: "ses_1", kind: :exception, message: "boom"})
      iex> {:ok, task} = Tet.Runtime.DiagnosticTask.new(error, "ses_1")
      iex> task.mode
      :diagnostic
  """
  @spec new(Tet.ErrorLog.t(), binary()) :: {:ok, t()} | {:error, term()}
  def new(%Tet.ErrorLog{} = error_log_entry, session_id)
      when is_binary(session_id) and session_id != "" do
    {:ok,
     %__MODULE__{
       id: generate_id(),
       session_id: session_id,
       error_log_entry: error_log_entry,
       repair_plan: nil,
       approval_status: nil,
       mode: :diagnostic,
       created_at: DateTime.utc_now(),
       metadata: %{}
     }}
  end

  def new(_error_log_entry, _session_id), do: {:error, :invalid_diagnostic_task}

  # ── Status ──────────────────────────────────────────────────────────────

  @doc """
  Derives the current task status from struct state.

  Status transitions:
    - `:diagnosing`       — diagnostic mode, no repair plan yet
    - `:plan_ready`       — repair plan submitted, awaiting approval
    - `:repair_approved`  — plan approved, ready for promotion
    - `:repair_active`    — promoted to full repair mode
  """
  @spec status(t()) :: status()
  def status(%__MODULE__{mode: :repair}), do: :repair_active
  def status(%__MODULE__{approval_status: :approved}), do: :repair_approved
  def status(%__MODULE__{repair_plan: plan}) when not is_nil(plan), do: :plan_ready
  def status(%__MODULE__{}), do: :diagnosing

  # ── Tool gating ─────────────────────────────────────────────────────────

  @doc """
  Checks whether a tool is allowed in the task's current mode.

  In diagnostic mode, only `@diagnostic_tools` are allowed.
  In repair mode, all tools are allowed (blocked tools are unlocked).

  Accepts both atom and string tool names.
  """
  @spec allowed_tool?(t(), tool_name() | binary()) :: boolean()
  def allowed_tool?(%__MODULE__{mode: :repair}, _tool), do: true

  def allowed_tool?(%__MODULE__{mode: :diagnostic}, tool) when is_atom(tool),
    do: tool in @diagnostic_tools

  def allowed_tool?(%__MODULE__{mode: :diagnostic}, tool) when is_binary(tool),
    do: tool in @diagnostic_tool_strings

  def allowed_tool?(%__MODULE__{mode: :diagnostic}, _tool), do: false

  # ── State transitions ──────────────────────────────────────────────────

  @doc """
  Submits a repair plan for the diagnostic task.

  Transitions status from `:diagnosing` to `:plan_ready` and sets
  approval_status to `:pending`.

  Returns `{:error, :plan_already_submitted}` if a plan already exists.
  """
  @spec submit_plan(t(), map()) :: {:ok, t()} | {:error, term()}
  def submit_plan(%__MODULE__{repair_plan: nil} = task, plan) when is_map(plan) do
    {:ok, %__MODULE__{task | repair_plan: plan, approval_status: :pending}}
  end

  def submit_plan(%__MODULE__{}, _plan), do: {:error, :plan_already_submitted}

  @doc """
  Approves a pending repair plan.

  Returns `{:error, :no_pending_plan}` if there is no plan awaiting approval.
  """
  @spec approve(t()) :: {:ok, t()} | {:error, term()}
  def approve(%__MODULE__{approval_status: :pending} = task) do
    {:ok, %__MODULE__{task | approval_status: :approved}}
  end

  def approve(%__MODULE__{}), do: {:error, :no_pending_plan}

  @doc """
  Rejects a pending repair plan, clearing it for re-submission.

  Returns `{:error, :no_pending_plan}` if there is no plan awaiting approval.
  """
  @spec reject(t()) :: {:ok, t()} | {:error, term()}
  def reject(%__MODULE__{approval_status: :pending} = task) do
    {:ok, %__MODULE__{task | approval_status: :rejected, repair_plan: nil}}
  end

  def reject(%__MODULE__{}), do: {:error, :no_pending_plan}

  @doc """
  Promotes the task from diagnostic to full repair mode.

  Requires `approval_status: :approved`. The second argument is optional
  metadata to merge into the task's metadata for audit purposes.

  Returns `{:error, :approval_required}` if the plan has not been approved.
  """
  @spec promote_to_repair(t(), map()) :: {:ok, t()} | {:error, term()}
  def promote_to_repair(task, repair_meta \\ %{})

  def promote_to_repair(%__MODULE__{approval_status: :approved} = task, repair_meta)
      when is_map(repair_meta) do
    merged = Map.merge(task.metadata, repair_meta)
    {:ok, %__MODULE__{task | mode: :repair, metadata: merged}}
  end

  def promote_to_repair(%__MODULE__{approval_status: :approved}, repair_meta)
      when not is_map(repair_meta) do
    {:error, :invalid_repair_metadata}
  end

  def promote_to_repair(%__MODULE__{}, _repair_meta), do: {:error, :approval_required}

  # ── Prompt generation ──────────────────────────────────────────────────

  @doc """
  Generates a diagnostic system prompt scoped to the error context.

  The prompt instructs the agent to focus on diagnosis only — reading,
  searching, and inspecting — without making any changes until a repair
  plan is approved.
  """
  @spec diagnostic_prompt(t()) :: binary()
  def diagnostic_prompt(%__MODULE__{} = task) do
    error = task.error_log_entry

    """
    ## Diagnostic Mode — BD-0059

    You are in DIAGNOSTIC-ONLY mode. Your task is to investigate and
    diagnose the following error. Do NOT patch, write, or execute shell
    commands until a repair plan has been submitted and approved.

    ### Error Context
    - **Error ID:** #{error.id}
    - **Kind:** #{error.kind}
    - **Message:**
      ```
      #{error.message}
      ```
    #{stacktrace_section(error.stacktrace)}
    ### Allowed Actions
    #{format_tool_list(@diagnostic_tools)}

    ### Blocked Actions (until repair plan approved)
    #{format_tool_list(@blocked_tools)}

    Focus on root-cause analysis. When you have a diagnosis, propose a
    repair plan for human review.
    """
    |> String.trim()
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp generate_id do
    time = System.system_time(:microsecond) |> Integer.to_string(36)
    unique = System.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
    "diag_#{time}_#{unique}"
  end

  defp stacktrace_section(nil), do: ""

  defp stacktrace_section(stacktrace) do
    "- **Stacktrace:**\n  ```\n  #{stacktrace}\n  ```\n"
  end

  defp format_tool_list(tools) do
    tools
    |> Enum.map(&"- `#{&1}`")
    |> Enum.join("\n")
  end
end
