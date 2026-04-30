defmodule Tet.PromptLab do
  @moduledoc """
  Pure Prompt Lab model and deterministic prompt refiner.

  Prompt Lab improves prompt wording and records structured quality feedback. It
  does not execute tools, call providers, read files, save chat messages, emit
  runtime events, or mutate anything by itself. Runtime may persist returned
  history entries through the dedicated prompt-history store only.
  """

  alias Tet.PromptLab.{Dimension, Preset, Refinement, Request}

  @version "tet.prompt_lab.v1"
  @default_preset_id "general"
  @dimension_ids ~w(
    clarity_specificity
    context_completeness
    constraint_handling
    ambiguity_control
    actionability
  )

  @doc "Returns the Prompt Lab model version."
  @spec version() :: binary()
  def version, do: @version

  @doc "Returns static Prompt Lab safety/boundary metadata."
  @spec boundary() :: map()
  def boundary do
    %{
      application: :tet_core,
      version: @version,
      side_effects: false,
      executes_tools: false,
      calls_providers: false,
      reads_workspace: false,
      mutates_runtime_state: false,
      runtime_allowed_store_writes: [:prompt_history]
    }
  end

  @doc "Returns the built-in quality dimensions in stable display order."
  @spec quality_dimensions() :: [Dimension.t()]
  def quality_dimensions do
    Enum.map(dimension_specs(), &dimension!/1)
  end

  @doc "Returns the stable built-in quality dimension ids."
  @spec quality_dimension_ids() :: [binary()]
  def quality_dimension_ids, do: @dimension_ids

  @doc "Fetches one built-in quality dimension by id."
  @spec get_quality_dimension(binary() | atom()) :: {:ok, Dimension.t()} | {:error, term()}
  def get_quality_dimension(id) do
    id = to_id(id)

    quality_dimensions()
    |> Enum.find(&(&1.id == id))
    |> case do
      nil -> {:error, {:unknown_prompt_lab_dimension, id}}
      dimension -> {:ok, dimension}
    end
  end

  @doc "Returns built-in Prompt Lab presets in stable display order."
  @spec presets() :: [Preset.t()]
  def presets do
    Enum.map(preset_specs(), &preset!/1)
  end

  @doc "Fetches one built-in Prompt Lab preset by id."
  @spec get_preset(binary() | atom()) :: {:ok, Preset.t()} | {:error, term()}
  def get_preset(id) do
    id = to_id(id)

    presets()
    |> Enum.find(&(&1.id == id))
    |> case do
      nil -> {:error, {:unknown_prompt_lab_preset, id}}
      preset -> {:ok, preset}
    end
  end

  @doc "Builds a validated refinement request without running the refiner."
  @spec request(map() | keyword()) :: {:ok, Request.t()} | {:error, term()}
  def request(attrs), do: Request.new(attrs)

  @doc "Validates a refiner output shape."
  @spec refinement(map() | keyword()) :: {:ok, Refinement.t()} | {:error, term()}
  def refinement(attrs), do: Refinement.new(attrs)

  @doc "Returns redacted refinement debug data without prompt text."
  @spec debug(Refinement.t()) :: map()
  def debug(%Refinement{} = refinement), do: Refinement.debug(refinement)

  @doc "Returns a stable redacted refinement debug snapshot without prompt text."
  @spec debug_text(Refinement.t()) :: binary()
  def debug_text(%Refinement{} = refinement), do: Refinement.debug_text(refinement)

  @doc "Refines a prompt with a built-in preset and explicit caller metadata."
  @spec refine(binary() | Request.t(), keyword()) :: {:ok, Refinement.t()} | {:error, term()}
  def refine(prompt, opts \\ [])

  def refine(prompt, opts) when is_binary(prompt) and is_list(opts) do
    preset_id = Keyword.get(opts, :preset_id, Keyword.get(opts, :preset, @default_preset_id))

    with {:ok, request} <-
           Request.new(%{
             prompt: prompt,
             preset_id: preset_id,
             dimensions: Keyword.get(opts, :dimensions, []),
             metadata: Keyword.get(opts, :metadata, %{})
           }) do
      refine(request, opts)
    end
  end

  def refine(%Request{} = request, opts) when is_list(opts) do
    with {:ok, preset} <- get_preset(request.preset_id),
         {:ok, dimensions} <- selected_dimensions(request, preset) do
      Tet.PromptLab.Refiner.refine(request, preset, dimensions, opts)
    end
  end

  def refine(_prompt, _opts), do: {:error, :invalid_request}

  defp selected_dimensions(%Request{dimensions: []}, %Preset{} = preset),
    do: dimensions_from_ids(preset.dimensions, preset)

  defp selected_dimensions(%Request{dimensions: dimensions}, %Preset{} = preset),
    do: dimensions_from_ids(dimensions, preset)

  defp dimensions_from_ids(ids, preset) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      id = to_id(id)

      cond do
        id not in @dimension_ids ->
          {:halt, {:error, {:unknown_prompt_lab_dimension, id}}}

        id not in preset.dimensions ->
          {:halt, {:error, {:prompt_lab_dimension_not_in_preset, id, preset.id}}}

        true ->
          {:ok, dimension} = get_quality_dimension(id)
          {:cont, {:ok, [dimension | acc]}}
      end
    end)
    |> case do
      {:ok, dimensions} -> {:ok, Enum.reverse(dimensions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dimension_specs do
    [
      %{
        id: "clarity_specificity",
        label: "Clarity & Specificity",
        description:
          "Checks whether the prompt states a clear objective with concrete requirements.",
        rubric: "1 is vague or implicit; 10 names the task, subject, and expected work product."
      },
      %{
        id: "context_completeness",
        label: "Context Completeness",
        description:
          "Checks whether enough project, audience, environment, or background context is present.",
        rubric: "1 has no usable context; 10 provides sufficient context for a focused answer."
      },
      %{
        id: "constraint_handling",
        label: "Constraint Handling",
        description:
          "Checks whether boundaries, non-goals, limitations, and must-follow requirements are explicit.",
        rubric:
          "1 has no boundaries; 10 clearly states constraints, exclusions, and safety limits."
      },
      %{
        id: "ambiguity_control",
        label: "Ambiguity Control",
        description: "Checks whether vague references and competing interpretations are reduced.",
        rubric: "1 leaves major ambiguity; 10 uses precise references and flags unknowns."
      },
      %{
        id: "actionability",
        label: "Actionability",
        description:
          "Checks whether deliverables, output format, success criteria, and validation are clear.",
        rubric:
          "1 is hard to act on; 10 tells the assistant exactly what to return and how to verify it."
      }
    ]
  end

  defp preset_specs do
    common_instructions = [
      "Improve prompt clarity, context, constraints, ambiguity control, and actionability.",
      "Ask clarifying questions when missing inputs would otherwise require guessing.",
      "Do not execute tools, call providers, mutate sessions, or persist outside Prompt Lab history."
    ]

    [
      %{
        id: "general",
        name: "General Prompt Review",
        description:
          "Balanced prompt improvement for everyday analysis, writing, and coordination tasks.",
        dimensions: @dimension_ids,
        instructions: common_instructions,
        tags: ["general", "review"],
        metadata: %{readonly: true}
      },
      %{
        id: "coding",
        name: "Coding Task Refiner",
        description:
          "Improves software-development prompts with implementation, boundary, and validation detail.",
        dimensions: @dimension_ids,
        instructions:
          common_instructions ++
            [
              "Call out affected files, existing patterns, tests, and acceptance checks when known.",
              "Preserve safety boundaries: suggested verification is text only, never executed by Prompt Lab."
            ],
        tags: ["code", "implementation", "tests"],
        metadata: %{readonly: true}
      },
      %{
        id: "planning",
        name: "Planning Prompt Refiner",
        description:
          "Improves planning prompts with scope, dependencies, risks, milestones, and decision points.",
        dimensions: @dimension_ids,
        instructions:
          common_instructions ++
            [
              "Separate required outcomes from optional enhancements.",
              "Make dependencies, risks, and verification evidence explicit."
            ],
        tags: ["planning", "scope", "risks"],
        metadata: %{readonly: true}
      }
    ]
  end

  defp dimension!(attrs) do
    {:ok, dimension} = Dimension.new(attrs)
    dimension
  end

  defp preset!(attrs) do
    {:ok, preset} = Preset.new(attrs)
    preset
  end

  defp to_id(id) when is_atom(id), do: Atom.to_string(id)
  defp to_id(id) when is_binary(id), do: id
  defp to_id(id), do: inspect(id)
end
