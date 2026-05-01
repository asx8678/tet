defmodule Tet.Runtime.DiagnosticTask.ToolFilter do
  @moduledoc """
  Tool filtering and categorization for diagnostic tasks — BD-0059.

  Given a diagnostic task's current mode, filters available tools down to
  only those permitted and provides human-readable explanations for why
  specific tools are blocked.

  This module is pure functions — no state, no side effects.
  """

  alias Tet.Runtime.DiagnosticTask

  @diagnostic_tools DiagnosticTask.diagnostic_tools()
  @diagnostic_tool_strings Enum.map(@diagnostic_tools, &Atom.to_string/1)
  @blocked_tools DiagnosticTask.blocked_tools()
  @blocked_tool_strings Enum.map(@blocked_tools, &Atom.to_string/1)

  @type tool_name :: atom() | binary()
  @type category :: :diagnostic | :mutating | :neutral

  # ── Filtering ───────────────────────────────────────────────────────────

  @doc """
  Filters a list of tool names to only those allowed by the task's current mode.

  In diagnostic mode, only diagnostic tools pass through.
  In repair mode, all tools are allowed.

  Accepts both atom and string tool names; returns them in their original form.

  ## Examples

      iex> task = %Tet.Runtime.DiagnosticTask{mode: :diagnostic, id: "d1", session_id: "s1",
      ...>   error_log_entry: struct(Tet.ErrorLog, %{id: "e1", session_id: "s1", kind: :exception, message: "x"})}
      iex> Tet.Runtime.DiagnosticTask.ToolFilter.filter_tools([:read, :patch, :search], task)
      [:read, :search]
  """
  @spec filter_tools([tool_name()], DiagnosticTask.t()) :: [tool_name()]
  def filter_tools(tools, %DiagnosticTask{} = task) when is_list(tools) do
    Enum.filter(tools, &DiagnosticTask.allowed_tool?(task, &1))
  end

  # ── Explanation ─────────────────────────────────────────────────────────

  @doc """
  Returns a human-readable explanation of why a tool is blocked.

  Returns `{:ok, reason}` when the tool is blocked, or `:allowed` when
  it is permitted in the task's current mode.

  ## Examples

      iex> task = %Tet.Runtime.DiagnosticTask{mode: :diagnostic, id: "d1", session_id: "s1",
      ...>   error_log_entry: struct(Tet.ErrorLog, %{id: "e1", session_id: "s1", kind: :exception, message: "x"})}
      iex> {:ok, reason} = Tet.Runtime.DiagnosticTask.ToolFilter.explain_blocked(:patch, task)
      iex> String.contains?(reason, "diagnostic")
      true
  """
  @spec explain_blocked(tool_name(), DiagnosticTask.t()) :: {:ok, binary()} | :allowed
  def explain_blocked(tool, %DiagnosticTask{} = task) do
    if DiagnosticTask.allowed_tool?(task, tool) do
      :allowed
    else
      {:ok, blocked_reason(tool, task)}
    end
  end

  # ── Categorization ─────────────────────────────────────────────────────

  @doc """
  Categorizes a tool as `:diagnostic`, `:mutating`, or `:neutral`.

  Tools in the diagnostic set are `:diagnostic`. Tools in the blocked set
  are `:mutating`. Everything else is `:neutral`.

  ## Examples

      iex> Tet.Runtime.DiagnosticTask.ToolFilter.tool_category(:read)
      :diagnostic

      iex> Tet.Runtime.DiagnosticTask.ToolFilter.tool_category(:patch)
      :mutating

      iex> Tet.Runtime.DiagnosticTask.ToolFilter.tool_category(:unknown_tool)
      :neutral
  """
  @spec tool_category(tool_name()) :: category()
  def tool_category(tool) when is_atom(tool) do
    cond do
      tool in @diagnostic_tools -> :diagnostic
      tool in @blocked_tools -> :mutating
      true -> :neutral
    end
  end

  def tool_category(tool) when is_binary(tool) do
    cond do
      tool in @diagnostic_tool_strings -> :diagnostic
      tool in @blocked_tool_strings -> :mutating
      true -> :neutral
    end
  end

  def tool_category(_tool), do: :neutral

  # ── Private helpers ─────────────────────────────────────────────────────

  defp blocked_reason(tool, %DiagnosticTask{} = task) do
    tool_str = to_string(tool)
    status = DiagnosticTask.status(task)

    case status do
      :diagnosing ->
        "`#{tool_str}` is blocked in diagnostic mode. " <>
          "Submit a repair plan and get it approved before using mutating tools."

      :plan_ready ->
        "`#{tool_str}` is blocked until the repair plan is approved. " <>
          "Awaiting human review."

      :repair_approved ->
        "`#{tool_str}` is blocked until the task is promoted to repair mode. " <>
          "Call promote_to_repair/2 to unlock mutating tools."

      :repair_active ->
        # Shouldn't reach here — repair mode allows all tools
        "`#{tool_str}` is allowed in repair mode."
    end
  end
end
