defmodule Tet.CLI.PromptLabTest do
  @moduledoc """
  CLI UX snapshot tests for Prompt Lab and command correction.

  Verifies that human-readable and JSON output modes are deterministic,
  scriptable, and include risk labels, "Did you mean" hints, and quality
  scoring output.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Tet.CLI.Render

  # ── Prompt Lab refinement rendering ─────────────────────────────────────

  describe "Render.prompt_lab_refinement/1" do
    test "formats an improved refinement with scores, changes, and prompt" do
      refinement = build_fixture_refinement(%{status: "improved"})
      output = Render.prompt_lab_refinement(refinement)

      assert output =~ "Prompt refinement improved"
      assert output =~ "preset: coding"
      assert output =~ "summary: Refined prompt structure"
      assert output =~ "clarity specificity: 4 → 8/10"
      assert output =~ "actionability: 4 → 9/10"
      assert output =~ "constraint handling: 4 → 8/10"
      assert output =~ "context completeness: 4 → 8/10"
      assert output =~ "ambiguity control: 4 → 8/10"
      assert output =~ "changes:"
      assert output =~ "clarified_task"
      assert output =~ "refined prompt:"
      assert output =~ "    Task:"
      assert output =~ "    Validation:"
    end

    test "includes clarifying questions when status is needs_clarification" do
      refinement =
        build_fixture_refinement(%{
          status: "needs_clarification",
          questions: [
            "What output format, success criteria, and validation evidence should be returned?",
            "What project, files, audience, runtime, or prior decisions should the assistant assume?"
          ]
        })

      output = Render.prompt_lab_refinement(refinement)

      assert output =~ "needs_clarification"
      assert output =~ "clarifying questions:"
      assert output =~ "? What output format"
    end

    test "omits empty changes section when no changes" do
      refinement = build_fixture_refinement(%{changes: []})
      output = Render.prompt_lab_refinement(refinement)

      refute output =~ "changes:"
    end

    test "includes warnings when present" do
      refinement =
        build_fixture_refinement(%{
          warnings: [
            "Prompt Lab is read-only: it refined wording only and did not execute tools."
          ]
        })

      output = Render.prompt_lab_refinement(refinement)
      assert output =~ "warnings:"
      assert output =~ "⚠ Prompt Lab is read-only"
    end
  end

  # ── Prompt Lab JSON rendering ───────────────────────────────────────────

  describe "Render.prompt_lab_refinement_json/1" do
    test "produces deterministic JSON with all refinement fields" do
      refinement = build_fixture_refinement(%{status: "improved"})
      json = Render.prompt_lab_refinement_json(refinement)
      decoded = Jason.decode!(json)

      assert decoded["id"] == "prompt-refinement-test-ux"
      assert decoded["status"] == "improved"
      assert decoded["preset_id"] == "coding"
      assert is_map(decoded["scores_before"])
      assert is_map(decoded["scores_after"])
      assert is_list(decoded["changes"])
      assert is_map(decoded["safety"])
      assert decoded["safety"]["mutates_outside_prompt_history"] == false
    end

    test "JSON round-trips through Refinement.from_map" do
      refinement = build_fixture_refinement(%{status: "improved"})
      map = Tet.PromptLab.Refinement.to_map(refinement)
      {:ok, restored} = Tet.PromptLab.Refinement.from_map(map)
      assert restored == refinement
    end
  end

  # ── Prompt Lab presets rendering ────────────────────────────────────────

  describe "Render.prompt_lab_presets/1" do
    test "lists all built-in presets with dimension count and tags" do
      presets = Tet.PromptLab.presets()
      output = Render.prompt_lab_presets(presets)

      assert output =~ "Prompt Lab presets:"
      assert output =~ "general: General Prompt Review"
      assert output =~ "coding: Coding Task Refiner"
      assert output =~ "planning: Planning Prompt Refiner"
      assert output =~ "5 dimensions"
      assert output =~ "tags:"
    end
  end

  describe "Render.prompt_lab_presets_json/1" do
    test "produces JSON array of preset maps" do
      presets = Tet.PromptLab.presets()
      json = Render.prompt_lab_presets_json(presets)
      decoded = Jason.decode!(json)

      ids = Enum.map(decoded, & &1["id"])
      assert "general" in ids
      assert "coding" in ids
      assert "planning" in ids
      assert Enum.all?(decoded, &is_list(&1["dimensions"]))
    end
  end

  # ── Prompt Lab dimensions rendering ─────────────────────────────────────

  describe "Render.prompt_lab_dimensions/1" do
    test "lists all quality dimensions with descriptions and rubrics" do
      dimensions = Tet.PromptLab.quality_dimensions()
      output = Render.prompt_lab_dimensions(dimensions)

      assert output =~ "Prompt Lab quality dimensions:"
      assert output =~ "clarity_specificity: Clarity & Specificity"
      assert output =~ "context_completeness: Context Completeness"
      assert output =~ "constraint_handling: Constraint Handling"
      assert output =~ "ambiguity_control: Ambiguity Control"
      assert output =~ "actionability: Actionability"
      assert output =~ "rubric:"
    end
  end

  describe "Render.prompt_lab_dimensions_json/1" do
    test "produces JSON array of dimension maps" do
      dimensions = Tet.PromptLab.quality_dimensions()
      json = Render.prompt_lab_dimensions_json(dimensions)
      decoded = Jason.decode!(json)

      ids = Enum.map(decoded, & &1["id"])
      assert "clarity_specificity" in ids
      labels = Enum.map(decoded, & &1["label"])
      assert "Clarity & Specificity" in labels
      assert Enum.all?(decoded, &is_integer(&1["score_min"]))
      assert Enum.all?(decoded, &is_integer(&1["score_max"]))
    end
  end

  # ── Command suggestion rendering (human-readable) ───────────────────────

  describe "Render.command_suggestions/1" do
    test "formats blocked critical suggestion with risk label" do
      suggestions = Tet.Command.Correction.suggest("rm -rf /", %{})
      output = Render.command_suggestions(suggestions)

      assert output =~ "Command corrections:"
      assert output =~ "🚫 Blocked"
      assert output =~ "no safe alternative"
      assert output =~ "Critical risk"
      assert output =~ "system-destructive"
    end

    test "formats modified suggestion with 'Did you mean' hint and risk label" do
      suggestions = Tet.Command.Correction.suggest("rm file.txt", %{})
      output = Render.command_suggestions(suggestions)

      assert output =~ "✏️  Did you mean:"
      assert output =~ "mv"
      assert output =~ "Trash"
      assert output =~ "risk:"
    end

    test "formats safe suggestion without blocking markers" do
      suggestions = Tet.Command.Correction.suggest("ls -la", %{})
      output = Render.command_suggestions(suggestions)

      assert output =~ "✅ Safe"
      assert output =~ "proceeding as-is"
      refute output =~ "🚫"
    end

    test "includes risk labels for all risk levels in output" do
      # Test all risk levels produce visible risk labels
      critical = Tet.Command.Correction.suggest("rm -rf /", %{})
      high = Tet.Command.Correction.suggest("rm file.txt", %{})
      medium = Tet.Command.Correction.suggest("sed -i 's/foo/bar/' config.txt", %{})
      low = Tet.Command.Correction.suggest("mkdir new_dir", %{})
      none = Tet.Command.Correction.suggest("ls -la", %{})

      assert Render.command_suggestions(critical) =~ "Critical risk"
      assert Render.command_suggestions(high) =~ "High risk"
      assert Render.command_suggestions(medium) =~ "Medium risk"
      assert Render.command_suggestions(low) =~ "Low risk"
      assert Render.command_suggestions(none) =~ "No risk"
    end
  end

  # ── Command suggestion JSON rendering ───────────────────────────────────

  describe "Render.command_suggestions_json/1" do
    test "produces deterministic JSON with all suggestion fields" do
      suggestions = Tet.Command.Correction.suggest("rm -rf /", %{})
      json = Render.command_suggestions_json(suggestions)
      decoded = Jason.decode!(json)

      first = List.first(decoded)
      assert first["original_command"] == "rm -rf /"
      assert first["risk_level"] == "critical"
      assert first["correction_type"] == "blocked"
      assert first["requires_gate"] == true
      assert is_binary(first["reason"])
    end

    test "JSON round-trips through Suggestion.from_map" do
      suggestions = Tet.Command.Correction.suggest("rm file.txt", %{})
      maps = Enum.map(suggestions, &Tet.Command.Suggestion.to_map/1)

      for map <- maps do
        {:ok, restored} = Tet.Command.Suggestion.from_map(map)
        assert restored.original_command == map.original_command
        assert Atom.to_string(restored.risk_level) == map.risk_level
        assert Atom.to_string(restored.correction_type) == map.correction_type
      end
    end
  end

  # ── CLI integration tests ───────────────────────────────────────────────

  describe "tet prompt-lab refine CLI command" do
    test "refine outputs human-readable refinement via CLI" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["prompt-lab", "refine", "Implement CLI sessions list"]) == 0
        end)

      assert output =~ "Prompt refinement"
      assert output =~ "preset: general"
      assert output =~ "clarity specificity:"
      assert output =~ "/10"
      assert output =~ "refined prompt:"
    end

    test "refine --json outputs JSON via CLI" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["prompt-lab", "refine", "--json", "Implement CLI sessions list"]) ==
                   0
        end)

      decoded = Jason.decode!(output)
      assert decoded["status"] == "improved"
      assert decoded["preset_id"] == "general"
      assert is_map(decoded["scores_before"])
      assert is_map(decoded["scores_after"])
      assert is_binary(decoded["refined_prompt"])
    end

    test "refine --preset coding uses specified preset" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run([
                   "prompt-lab",
                   "refine",
                   "--preset",
                   "coding",
                   "Implement CLI sessions list"
                 ]) == 0
        end)

      assert output =~ "preset: coding"
    end

    test "refine with empty prompt shows usage error" do
      output =
        capture_io(:stderr, fn ->
          assert Tet.CLI.run(["prompt-lab", "refine"]) == 64
        end)

      assert output =~ "usage: tet prompt-lab refine"
    end

    test "refine with missing --preset value shows usage error" do
      output =
        capture_io(:stderr, fn ->
          assert Tet.CLI.run(["prompt-lab", "refine", "--preset"]) == 64
        end)

      assert output =~ "--preset requires"
    end
  end

  describe "tet prompt-lab presets CLI command" do
    test "lists presets in human-readable format" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["prompt-lab", "presets"]) == 0
        end)

      assert output =~ "Prompt Lab presets:"
      assert output =~ "general: General Prompt Review"
      assert output =~ "coding: Coding Task Refiner"
    end

    test "lists presets as JSON with --json flag" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["prompt-lab", "presets", "--json"]) == 0
        end)

      decoded = Jason.decode!(output)
      ids = Enum.map(decoded, & &1["id"])
      assert "general" in ids
      assert "coding" in ids
    end
  end

  describe "tet prompt-lab dimensions CLI command" do
    test "lists dimensions in human-readable format" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["prompt-lab", "dimensions"]) == 0
        end)

      assert output =~ "Prompt Lab quality dimensions:"
      assert output =~ "clarity_specificity"
      assert output =~ "Clarity & Specificity"
    end

    test "lists dimensions as JSON with --json flag" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["prompt-lab", "dimensions", "--json"]) == 0
        end)

      decoded = Jason.decode!(output)
      ids = Enum.map(decoded, & &1["id"])
      assert "clarity_specificity" in ids
    end
  end

  describe "tet correct CLI command" do
    test "correct outputs human-readable suggestions with risk labels" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["correct", "rm", "-rf", "/"]) == 0
        end)

      assert output =~ "Command corrections:"
      assert output =~ "🚫 Blocked"
      assert output =~ "Critical risk"
      assert output =~ "system-destructive"
    end

    test "correct outputs JSON with --json flag" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["correct", "--json", "rm", "file.txt"]) == 0
        end)

      decoded = Jason.decode!(output)
      first = List.first(decoded)
      assert first["original_command"] == "rm file.txt"
      assert first["risk_level"] == "high"
      assert first["correction_type"] == "modified"
    end

    test "correct shows 'Did you mean' for modified commands" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["correct", "rm", "file.txt"]) == 0
        end)

      assert output =~ "✏️  Did you mean:"
      assert output =~ "mv"
      assert output =~ "risk:"
      assert output =~ "High risk"
    end

    test "correct with empty command shows usage error" do
      output =
        capture_io(:stderr, fn ->
          assert Tet.CLI.run(["correct"]) == 64
        end)

      assert output =~ "usage: tet correct"
    end

    test "correct shows safe label for low-risk commands" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["correct", "ls", "-la"]) == 0
        end)

      assert output =~ "✅ Safe"
      assert output =~ "No risk"
    end
  end

  describe "help output includes new commands" do
    test "help mentions prompt-lab and correct commands" do
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["help"]) == 0
        end)

      assert output =~ "prompt-lab"
      assert output =~ "correct"
      assert output =~ "Refine a prompt"
      assert output =~ "Suggest safer command alternatives"
    end
  end

  # ── Test helpers ─────────────────────────────────────────────────────────

  defp build_fixture_refinement(overrides) do
    default = %{
      id: "prompt-refinement-test-ux",
      preset_id: "coding",
      status: "improved",
      original_prompt: "Implement CLI sessions list",
      refined_prompt: """
      Task:
      \s
      Implement CLI sessions list.
      \s
      Validation:
      \s
      Include tests and acceptance checks.\
      """,
      summary: "Refined prompt structure with 5 dimension-linked improvements.",
      scores_before: %{
        "clarity_specificity" => %{
          score: 4,
          comment: "Clarify the goal and name the concrete work product."
        },
        "context_completeness" => %{
          score: 4,
          comment: "Add project, audience, files, environment, or background context."
        },
        "constraint_handling" => %{
          score: 4,
          comment: "State boundaries, exclusions, and must-follow requirements."
        },
        "ambiguity_control" => %{
          score: 4,
          comment: "Replace vague references with named subjects and expected behavior."
        },
        "actionability" => %{
          score: 4,
          comment: "Specify output format, success criteria, and validation expectations."
        }
      },
      scores_after: %{
        "clarity_specificity" => %{score: 8, comment: "Clear task language with concrete intent."},
        "context_completeness" => %{
          score: 8,
          comment: "Context is sufficient for a focused response."
        },
        "constraint_handling" => %{score: 8, comment: "Constraints and non-goals are visible."},
        "ambiguity_control" => %{
          score: 8,
          comment: "Wording leaves little room for competing interpretations."
        },
        "actionability" => %{
          score: 9,
          comment: "Deliverables and verification steps are actionable."
        }
      },
      changes: [
        %{
          dimension: "clarity_specificity",
          kind: "clarified_task",
          rationale: "The refined prompt names the task as a concrete work item.",
          impact: "high"
        },
        %{
          dimension: "context_completeness",
          kind: "added_context_slot",
          rationale:
            "The refined prompt asks for project and runtime context instead of assuming it.",
          impact: "high"
        },
        %{
          dimension: "constraint_handling",
          kind: "added_constraints_slot",
          rationale:
            "The refined prompt creates an explicit place for constraints and non-goals.",
          impact: "high"
        },
        %{
          dimension: "ambiguity_control",
          kind: "called_out_ambiguity",
          rationale: "The refined prompt surfaces vague references as clarifying questions.",
          impact: "high"
        },
        %{
          dimension: "actionability",
          kind: "added_output_and_validation",
          rationale:
            "The refined prompt requests deliverables, success criteria, and validation evidence.",
          impact: "high"
        }
      ],
      questions: [],
      warnings: [],
      metadata: %{refiner: "deterministic_prompt_lab_v1", preset_name: "Coding Task Refiner"},
      safety: %{
        "mutates_outside_prompt_history" => false,
        "provider_called" => false,
        "tools_executed" => false
      }
    }

    merged =
      Map.merge(
        default,
        Map.take(overrides, [:status, :changes, :questions, :warnings, :metadata])
      )

    case Tet.PromptLab.Refinement.new(merged) do
      {:ok, refinement} -> refinement
      {:error, reason} -> raise "failed to build fixture refinement: #{inspect(reason)}"
    end
  end
end
