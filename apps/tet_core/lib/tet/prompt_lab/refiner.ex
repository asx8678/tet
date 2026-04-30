defmodule Tet.PromptLab.Refiner do
  @moduledoc false

  alias Tet.PromptLab.{Dimension, Preset, Refinement, Request}

  @spec refine(Request.t(), Preset.t(), [Dimension.t()], keyword()) ::
          {:ok, Refinement.t()} | {:error, term()}
  def refine(%Request{} = request, %Preset{} = preset, dimensions, opts) when is_list(opts) do
    original_prompt = request.prompt
    before_scores = score_entries(original_prompt, dimensions)
    questions = questions(original_prompt, before_scores)
    status = status(before_scores, questions)
    refined_prompt = refined_prompt(original_prompt, preset, before_scores, questions, status)
    after_scores = score_entries(refined_prompt, dimensions)
    changes = changes(before_scores, after_scores)
    warnings = warnings(original_prompt)

    Refinement.new(%{
      id: Keyword.get(opts, :refinement_id),
      preset_id: preset.id,
      preset_version: preset.version,
      status: status,
      original_prompt: original_prompt,
      refined_prompt: refined_prompt,
      summary: summary(status, changes, questions),
      scores_before: before_scores,
      scores_after: after_scores,
      changes: changes,
      questions: questions,
      warnings: warnings,
      metadata: result_metadata(request, preset),
      safety: %{
        "mutates_outside_prompt_history" => false,
        "provider_called" => false,
        "tools_executed" => false
      }
    })
  end

  defp score_entries(prompt, dimensions) do
    Map.new(dimensions, fn dimension ->
      score = score_dimension(dimension.id, prompt)
      {dimension.id, %{"score" => score, "comment" => score_comment(dimension.id, score)}}
    end)
  end

  defp score_dimension("clarity_specificity", prompt) do
    2
    |> add(if word_count(prompt) >= 8, do: 2, else: 0)
    |> add(if word_count(prompt) >= 20, do: 1, else: 0)
    |> add(if task_verb?(prompt), do: 2, else: 0)
    |> add(if String.match?(prompt, ~r/[.?!]/), do: 1, else: 0)
    |> clamp_score()
  end

  defp score_dimension("context_completeness", prompt) do
    2
    |> add(min(marker_count(prompt, context_markers()), 3) * 2)
    |> add(if word_count(prompt) >= 30, do: 1, else: 0)
    |> add(
      if String.match?(prompt, ~r/\b[\w.\/-]+\.(ex|exs|md|json|txt|py|js|ts)\b/i), do: 1, else: 0
    )
    |> clamp_score()
  end

  defp score_dimension("constraint_handling", prompt) do
    2
    |> add(min(marker_count(prompt, constraint_markers()), 4) * 2)
    |> clamp_score()
  end

  defp score_dimension("ambiguity_control", prompt) do
    (8 - vague_count(prompt) * 2)
    |> add(if word_count(prompt) >= 12, do: 1, else: 0)
    |> add(if String.match?(prompt, ~r/\b(this|that|it|stuff|thing)\b/i), do: -1, else: 0)
    |> clamp_score()
  end

  defp score_dimension("actionability", prompt) do
    2
    |> add(if task_verb?(prompt), do: 2, else: 0)
    |> add(if marker_count(prompt, output_markers()) > 0, do: 2, else: 0)
    |> add(if marker_count(prompt, validation_markers()) > 0, do: 2, else: 0)
    |> add(if marker_count(prompt, constraint_markers()) > 0, do: 1, else: 0)
    |> clamp_score()
  end

  defp score_dimension(_dimension, _prompt), do: 1

  defp score_comment("clarity_specificity", score) when score >= 8,
    do: "Clear task language with concrete intent."

  defp score_comment("clarity_specificity", _score),
    do: "Clarify the goal and name the concrete work product."

  defp score_comment("context_completeness", score) when score >= 8,
    do: "Context is sufficient for a focused response."

  defp score_comment("context_completeness", _score),
    do: "Add project, audience, files, environment, or background context."

  defp score_comment("constraint_handling", score) when score >= 8,
    do: "Constraints and non-goals are visible."

  defp score_comment("constraint_handling", _score),
    do: "State boundaries, exclusions, and must-follow requirements."

  defp score_comment("ambiguity_control", score) when score >= 8,
    do: "Wording leaves little room for competing interpretations."

  defp score_comment("ambiguity_control", _score),
    do: "Replace vague references with named subjects and expected behavior."

  defp score_comment("actionability", score) when score >= 8,
    do: "Deliverables and verification steps are actionable."

  defp score_comment("actionability", _score),
    do: "Specify output format, success criteria, and validation expectations."

  defp questions(prompt, scores) do
    []
    |> maybe_question(score(scores, "ambiguity_control") <= 4, ambiguous_question(prompt))
    |> maybe_question(score(scores, "context_completeness") <= 4, context_question())
    |> maybe_question(score(scores, "constraint_handling") <= 4, constraint_question())
    |> maybe_question(score(scores, "actionability") <= 4, actionability_question())
    |> Enum.reverse()
  end

  defp maybe_question(questions, false, _question), do: questions
  defp maybe_question(questions, true, nil), do: questions
  defp maybe_question(questions, true, question), do: [question | questions]

  defp ambiguous_question(prompt) do
    if String.match?(prompt, ~r/\b(this|that|it|stuff|thing|better|fix)\b/i) do
      "What exact subject should replace vague references like this/that/it/stuff/fix?"
    end
  end

  defp context_question do
    "What project, files, audience, runtime, or prior decisions should the assistant assume?"
  end

  defp constraint_question do
    "What constraints, exclusions, safety boundaries, or non-goals must be respected?"
  end

  defp actionability_question do
    "What output format, success criteria, and validation evidence should be returned?"
  end

  defp status(scores, questions) do
    cond do
      average_score(scores) >= 8 and questions == [] ->
        "unchanged"

      score(scores, "ambiguity_control") <= 5 and score(scores, "context_completeness") <= 4 ->
        "needs_clarification"

      true ->
        "improved"
    end
  end

  defp refined_prompt(original_prompt, _preset, _scores, _questions, "unchanged"),
    do: original_prompt

  defp refined_prompt(original_prompt, preset, scores, questions, _status) do
    sections = [
      "Task:\n#{normalize_task(original_prompt)}",
      "Context:\n- Describe the relevant project, files, runtime, audience, and prior decisions before answering.",
      "Constraints:\n- State hard requirements, non-goals, safety boundaries, and anything the assistant must not change.",
      "Output:\n- Return the answer in a clear structure with concrete deliverables and assumptions.",
      "Validation:\n- Include checks, tests, or evidence that show the result satisfies the request."
    ]

    preset_section =
      if preset.id == "coding" do
        [
          "Coding focus:",
          "- Preserve existing behavior unless explicitly asked to change it.",
          "- Mention affected files and verification commands without assuming they have been run."
        ]
        |> Enum.join("\n")
      end

    clarification_section =
      if questions == [] do
        nil
      else
        "Clarifying questions:\n" <> Enum.map_join(questions, "\n", &"- #{&1}")
      end

    improvement_note =
      "Prompt quality focus: #{weak_dimension_labels(scores)}."

    [sections, preset_section, clarification_section, improvement_note]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp normalize_task(prompt) do
    prompt = String.trim(prompt)

    if String.match?(prompt, ~r/[.?!]$/) do
      prompt
    else
      prompt <> "."
    end
  end

  defp weak_dimension_labels(scores) do
    scores
    |> Enum.filter(fn {_dimension, entry} -> entry["score"] < 8 end)
    |> Enum.map(fn {dimension, _entry} -> String.replace(dimension, "_", " ") end)
    |> case do
      [] -> "maintain current clarity"
      labels -> Enum.join(labels, ", ")
    end
  end

  defp changes(before_scores, after_scores) do
    before_scores
    |> Enum.reduce([], fn {dimension, before}, acc ->
      after_entry = Map.fetch!(after_scores, dimension)
      diff = after_entry["score"] - before["score"]

      if diff > 0 do
        [change(dimension, diff) | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp change(dimension, diff) do
    %{
      "dimension" => dimension,
      "kind" => change_kind(dimension),
      "rationale" => change_rationale(dimension),
      "impact" => if(diff >= 3, do: "high", else: "medium")
    }
  end

  defp change_kind("clarity_specificity"), do: "clarified_task"
  defp change_kind("context_completeness"), do: "added_context_slot"
  defp change_kind("constraint_handling"), do: "added_constraints_slot"
  defp change_kind("ambiguity_control"), do: "called_out_ambiguity"
  defp change_kind("actionability"), do: "added_output_and_validation"
  defp change_kind(_dimension), do: "refined_wording"

  defp change_rationale("clarity_specificity"),
    do: "The refined prompt names the task as a concrete work item."

  defp change_rationale("context_completeness"),
    do: "The refined prompt asks for project and runtime context instead of assuming it."

  defp change_rationale("constraint_handling"),
    do: "The refined prompt creates an explicit place for constraints and non-goals."

  defp change_rationale("ambiguity_control"),
    do: "The refined prompt surfaces vague references as clarifying questions."

  defp change_rationale("actionability"),
    do: "The refined prompt requests deliverables, success criteria, and validation evidence."

  defp change_rationale(_dimension), do: "The refined prompt improves the requested dimension."

  defp warnings(prompt) do
    if String.match?(prompt, ~r/\b(run|execute|tool|command|shell|apply patch|delete|rm -rf)\b/i) do
      [
        "Prompt Lab is read-only: it refined wording only and did not execute tools, commands, providers, patches, or file mutations."
      ]
    else
      []
    end
  end

  defp summary("unchanged", _changes, _questions),
    do: "Prompt already meets the selected Prompt Lab quality dimensions."

  defp summary("needs_clarification", changes, questions) do
    "Prompt needs clarification before reliable execution; generated a safer scaffold with #{length(changes)} improvements and #{length(questions)} question(s)."
  end

  defp summary("improved", changes, questions) do
    "Refined prompt structure with #{length(changes)} dimension-linked improvement(s) and #{length(questions)} clarifying question(s)."
  end

  defp result_metadata(%Request{} = request, %Preset{} = preset) do
    request.metadata
    |> Map.put("preset_name", preset.name)
    |> Map.put("refiner", "deterministic_prompt_lab_v1")
  end

  defp score(scores, dimension) do
    case Map.fetch(scores, dimension) do
      {:ok, %{"score" => score}} -> score
      :error -> 10
    end
  end

  defp average_score(scores) when map_size(scores) == 0, do: 0

  defp average_score(scores) do
    total = scores |> Map.values() |> Enum.map(& &1["score"]) |> Enum.sum()
    total / map_size(scores)
  end

  defp word_count(prompt), do: prompt |> String.split(~r/\s+/, trim: true) |> length()

  defp task_verb?(prompt) do
    String.match?(
      prompt,
      ~r/\b(analyze|build|create|debug|document|explain|fix|implement|improve|plan|refactor|review|summarize|test|write)\b/i
    )
  end

  defp marker_count(markers, prompt) when is_list(markers) and is_binary(prompt) do
    Enum.count(markers, &String.match?(prompt, &1))
  end

  defp marker_count(prompt, markers) do
    Enum.count(markers, &String.match?(prompt, &1))
  end

  defp context_markers do
    [
      ~r/\bcontext\b/i,
      ~r/\bproject\b/i,
      ~r/\bfile(s)?\b/i,
      ~r/\bruntime\b/i,
      ~r/\benvironment\b/i,
      ~r/\buser(s)?\b/i,
      ~r/\bbecause\b/i,
      ~r/\busing\b/i
    ]
  end

  defp constraint_markers do
    [
      ~r/\bmust\b/i,
      ~r/\bshould\b/i,
      ~r/\bdo not\b/i,
      ~r/\bdon't\b/i,
      ~r/\bavoid\b/i,
      ~r/\bonly\b/i,
      ~r/\bwithout\b/i,
      ~r/\bkeep\b/i,
      ~r/\bno\b/i
    ]
  end

  defp output_markers do
    [
      ~r/\breturn\b/i,
      ~r/\boutput\b/i,
      ~r/\bdeliverable(s)?\b/i,
      ~r/\bformat\b/i,
      ~r/\binclude\b/i,
      ~r/\bsummar(y|ize)\b/i
    ]
  end

  defp validation_markers do
    [
      ~r/\bacceptance\b/i,
      ~r/\bsuccess\b/i,
      ~r/\btest(s|ed|ing)?\b/i,
      ~r/\bcheck(s|ed|ing)?\b/i,
      ~r/\bverify\b/i,
      ~r/\bevidence\b/i
    ]
  end

  defp vague_count(prompt) do
    marker_count(
      [
        ~r/\bfix (it|this|that)\b/i,
        ~r/\bmake (it|this|that) better\b/i,
        ~r/\bstuff\b/i,
        ~r/\bthing(s)?\b/i,
        ~r/\bwhatever\b/i,
        ~r/\betc\b/i,
        ~r/\bASAP\b/i
      ],
      prompt
    )
  end

  defp add(score, amount), do: score + amount
  defp clamp_score(score), do: max(1, min(10, score))
end
