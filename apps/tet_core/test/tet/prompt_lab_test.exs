defmodule Tet.PromptLabTest do
  use ExUnit.Case, async: true

  test "built-in presets and quality dimensions are valid and stable" do
    assert Tet.PromptLab.boundary().executes_tools == false
    assert Tet.PromptLab.boundary().calls_providers == false

    assert Tet.PromptLab.quality_dimension_ids() == [
             "clarity_specificity",
             "context_completeness",
             "constraint_handling",
             "ambiguity_control",
             "actionability"
           ]

    dimensions = Tet.PromptLab.quality_dimensions()
    assert Enum.map(dimensions, & &1.id) == Tet.PromptLab.quality_dimension_ids()
    assert Enum.all?(dimensions, &Tet.PromptLab.Dimension.valid_score?(&1, 10))
    refute Enum.any?(dimensions, &Tet.PromptLab.Dimension.valid_score?(&1, 11))

    assert {:ok, coding} = Tet.PromptLab.get_preset("coding")
    assert coding.version == "tet.prompt_lab.preset.v1"
    assert coding.dimensions == Tet.PromptLab.quality_dimension_ids()
    assert "code" in coding.tags

    assert {:error, {:unknown_prompt_lab_preset, "wat"}} = Tet.PromptLab.get_preset("wat")
  end

  test "refines prompts with a deterministic redacted debug snapshot" do
    assert {:ok, refinement} =
             Tet.PromptLab.refine(
               "Implement CLI sessions list",
               preset: "coding",
               dimensions: ["clarity_specificity", "actionability"],
               refinement_id: "prompt-refinement-fixture",
               metadata: %{api_key: "secret", trace_id: "trace-47"}
             )

    assert refinement.status == "improved"

    assert refinement.safety == %{
             "mutates_outside_prompt_history" => false,
             "provider_called" => false,
             "tools_executed" => false
           }

    assert refinement.scores_after["clarity_specificity"]["score"] >
             refinement.scores_before["clarity_specificity"]["score"]

    assert refinement.scores_after["actionability"]["score"] >
             refinement.scores_before["actionability"]["score"]

    assert Enum.map(refinement.changes, & &1["dimension"]) == [
             "actionability",
             "clarity_specificity"
           ]

    assert refinement.questions == [
             "What output format, success criteria, and validation evidence should be returned?"
           ]

    assert refinement.original_prompt == "Implement CLI sessions list"
    assert refinement.refined_prompt =~ "Task:\nImplement CLI sessions list."
    assert refinement.refined_prompt =~ "Validation:"

    debug_text = Tet.PromptLab.debug_text(refinement)

    refute debug_text =~ "Implement CLI sessions list"
    refute debug_text =~ "secret"
    assert debug_text == refinement_debug_snapshot()

    assert {:ok, round_tripped} =
             refinement
             |> Tet.PromptLab.Refinement.to_map()
             |> Tet.PromptLab.Refinement.from_map()

    assert round_tripped == refinement
  end

  test "generates stable default refinement and history ids" do
    assert {:ok, refinement} =
             Tet.PromptLab.refine("Implement CLI sessions list", preset: "coding")

    assert String.starts_with?(refinement.id, "prompt-refinement-")

    assert {:ok, request} =
             Tet.PromptLab.Request.new(%{
               prompt: "Implement CLI sessions list",
               preset_id: "coding"
             })

    assert {:ok, history} =
             Tet.PromptLab.HistoryEntry.new(%{
               created_at: "2025-01-01T00:00:00.000Z",
               request: request,
               result: refinement
             })

    assert String.starts_with?(history.id, "prompt-history-")
  end

  test "ambiguous prompts surface clarification questions instead of pretending to execute" do
    assert {:ok, refinement} =
             Tet.PromptLab.refine("fix it",
               preset: "general",
               refinement_id: "prompt-refinement-ambiguous"
             )

    assert refinement.status == "needs_clarification"
    assert refinement.questions != []
    assert refinement.safety["tools_executed"] == false
    assert refinement.safety["provider_called"] == false
    assert refinement.safety["mutates_outside_prompt_history"] == false
    assert refinement.refined_prompt =~ "Clarifying questions:"
  end

  test "refiner output validation rejects executable-looking fields and unsafe safety flags" do
    assert {:ok, refinement} =
             Tet.PromptLab.refine("Implement CLI sessions list",
               preset: "coding",
               refinement_id: "prompt-refinement-validation"
             )

    valid = Tet.PromptLab.Refinement.to_map(refinement)

    assert {:error, {:invalid_refinement_field, "tool_calls"}} =
             valid
             |> Map.put(:tool_calls, [%{name: "run_shell"}])
             |> Tet.PromptLab.Refinement.from_map()

    assert {:error, :invalid_refinement_safety} =
             valid
             |> Map.put(:safety, %{"tools_executed" => true})
             |> Tet.PromptLab.Refinement.from_map()
  end

  defp refinement_debug_snapshot do
    """
    tet.prompt_lab.refinement.v1 id=prompt-refinement-fixture preset=coding status=improved
    original_sha256=44aa779370138c565aa5d82f60e9e510e99d9c1dc25d8e0dcb125698b7455e8f refined_sha256=ed2607c047c9336f1090c950a4a68fe76463fc7e5054bf7c3c6e21bafaaaf87e
    scores_before={"actionability":{"comment":"Specify output format, success criteria, and validation expectations.","score":4},"clarity_specificity":{"comment":"Clarify the goal and name the concrete work product.","score":4}}
    scores_after={"actionability":{"comment":"Deliverables and verification steps are actionable.","score":9},"clarity_specificity":{"comment":"Clear task language with concrete intent.","score":8}}
    changes=2 questions=1 warnings=0 safety={"mutates_outside_prompt_history":false,"provider_called":false,"tools_executed":false} metadata={"api_key":"[REDACTED]","preset_name":"Coding Task Refiner","refiner":"deterministic_prompt_lab_v1","trace_id":"trace-47"}
    """
  end
end
