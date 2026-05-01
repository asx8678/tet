defmodule Tet.TaskManager.Guidance do
  @moduledoc """
  Category-based guidance event generation — BD-0023.

  Produces deterministic guidance hints based on the active task's category,
  integrating with `Tet.PlanMode.Policy` (BD-0025) categories. Guidance events
  steer the runtime toward appropriate tool usage without blocking or
  side-effecting.

  ## Relationship to plan mode

  - Plan-safe categories (`:researching`, `:planning`) produce guidance that
    reminds the agent to stay in read-only territory.
  - Acting categories (`:acting`, `:verifying`, `:debugging`) produce guidance
    that unlocks write/edit/shell tools and warns about appropriate scope.

  This module is pure data. It does not dispatch tools, emit events to buses,
  or interact with the filesystem.
  """

  alias Tet.PlanMode.Policy
  alias Tet.TaskManager.Task

  @type guidance_type :: :research | :plan | :act | :verify | :debug | :document | :none
  @type guidance_result :: {:guidance, guidance_type(), binary()} | :no_active_task

  @guidance_messages %{
    researching:
      "Task is in researching phase. Use read-only tools (read, list, search) to gather information. " <>
        "Commit to planning or acting to progress.",
    planning:
      "Task is in planning phase. Read-only tools are available for analysis. " <>
        "Transition to acting to unlock write, edit, and shell tools.",
    acting:
      "Task is in acting phase. Write, edit, and shell tools are unlocked. " <>
        "Focus on implementing the planned changes.",
    verifying:
      "Task is in verification phase. Run tests and validation to confirm changes. " <>
        "Use read tools to inspect results.",
    documenting:
      "Task is in documentation phase. Write docs, comments, and README updates. " <>
        "Use write tools to persist documentation artifacts.",
    debugging:
      "Task is in debugging phase. Shell and diagnostic tools are available. " <>
        "Investigate and fix the issue before returning to acting."
  }

  @doc "Returns guidance for the active task in the given TaskManager state."
  @spec for_state(Tet.TaskManager.State.t()) :: guidance_result()
  def for_state(%Tet.TaskManager.State{active_task_id: nil}), do: :no_active_task

  def for_state(%Tet.TaskManager.State{} = state) do
    case Tet.TaskManager.State.active_task(state) do
      %Task{category: category} -> for_category(category)
      nil -> :no_active_task
    end
  end

  @all_categories Policy.all_categories()

  @doc "Returns guidance for a specific category."
  @spec for_category(Task.category()) :: {:guidance, guidance_type(), binary()} | :no_active_task
  def for_category(category) when category in @all_categories do
    type = category_to_guidance_type(category)
    message = Map.get(@guidance_messages, category, "No guidance available.")
    {:guidance, type, message}
  end

  @doc "Returns true when the category is plan-safe (researching/planning)."
  @spec plan_safe?(Task.category()) :: boolean()
  def plan_safe?(category), do: Policy.plan_safe_category?(Policy.default(), category)

  @doc "Returns true when the category unlocks mutating tools (acting/verifying/debugging)."
  @spec acting?(Task.category()) :: boolean()
  def acting?(category), do: Policy.acting_category?(Policy.default(), category)

  @doc "Returns the guidance message for a category, or nil."
  @spec message(Task.category()) :: binary() | nil
  def message(category) do
    Map.get(@guidance_messages, category)
  end

  @doc "Returns all guidance messages."
  @spec all_messages() :: %{Task.category() => binary()}
  def all_messages, do: @guidance_messages

  @doc "Converts a task category to its guidance type atom."
  @spec category_to_guidance_type(Task.category()) :: guidance_type()
  def category_to_guidance_type(:researching), do: :research
  def category_to_guidance_type(:planning), do: :plan
  def category_to_guidance_type(:acting), do: :act
  def category_to_guidance_type(:verifying), do: :verify
  def category_to_guidance_type(:documenting), do: :document
  def category_to_guidance_type(:debugging), do: :debug
  def category_to_guidance_type(_), do: :none

  @doc "Converts a guidance type back to a task category, or nil."
  @spec guidance_type_to_category(guidance_type()) :: Task.category() | nil
  def guidance_type_to_category(:research), do: :researching
  def guidance_type_to_category(:plan), do: :planning
  def guidance_type_to_category(:act), do: :acting
  def guidance_type_to_category(:verify), do: :verifying
  def guidance_type_to_category(:document), do: :documenting
  def guidance_type_to_category(:debug), do: :debugging
  def guidance_type_to_category(_), do: nil
end
