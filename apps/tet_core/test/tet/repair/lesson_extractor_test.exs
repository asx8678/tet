defmodule Tet.Repair.LessonExtractorTest do
  use ExUnit.Case, async: true

  @moduletag :tet_core

  alias Tet.Repair
  alias Tet.Repair.LessonExtractor

  # -- Helpers --

  defp repair_context(overrides \\ %{}) do
    repair_attrs =
      Map.merge(
        %{
          id: "rep_001",
          error_log_id: "err_001",
          session_id: "ses_001",
          strategy: :patch,
          params: %{file: "lib/bug.ex"},
          status: :succeeded
        },
        Map.get(overrides, :repair_overrides, %{})
      )

    {:ok, repair} = Repair.new(repair_attrs)
    Map.merge(%{repair: repair}, Map.drop(overrides, [:repair_overrides]))
  end

  # -- extract/1 --

  describe "extract/1" do
    test "extracts a ProjectLesson from a succeeded patch repair" do
      ctx = repair_context()
      assert {:ok, lesson} = LessonExtractor.extract(ctx)

      assert lesson.id == "les_rep_001"
      assert lesson.source_finding_id == "err_001"
      assert lesson.session_id == "ses_001"
      assert lesson.category == :repair_strategy
      assert is_binary(lesson.description)
      assert is_list(lesson.evidence_refs)
      assert lesson.metadata["repair_id"] == "rep_001"
      assert lesson.metadata["source"] == "lesson_extractor"
    end

    test "extracts a lesson from a fallback repair" do
      ctx = repair_context(%{repair_overrides: %{strategy: :fallback}})
      assert {:ok, lesson} = LessonExtractor.extract(ctx)
      assert lesson.category == :repair_strategy
      assert lesson.metadata["extractor_category"] == "workaround"
    end

    test "extracts a lesson from a human repair" do
      ctx = repair_context(%{repair_overrides: %{strategy: :human, params: %{notes: "manual"}}})
      assert {:ok, lesson} = LessonExtractor.extract(ctx)
      assert lesson.category == :error_pattern
      assert lesson.metadata["extractor_category"] == "root_cause"
    end

    test "extracts a lesson from a retry repair with params" do
      ctx = repair_context(%{repair_overrides: %{strategy: :retry, params: %{attempt: 3}}})
      assert {:ok, lesson} = LessonExtractor.extract(ctx)
      assert lesson.category == :error_pattern
    end

    test "includes checkpoint in evidence refs when provided" do
      ctx = repair_context(%{checkpoint_id: "cp_001"})
      assert {:ok, lesson} = LessonExtractor.extract(ctx)

      assert Enum.any?(lesson.evidence_refs, fn ref ->
               ref["type"] == "checkpoint" and ref["id"] == "cp_001"
             end)
    end

    test "always includes repair and error_log in evidence refs" do
      ctx = repair_context()
      assert {:ok, lesson} = LessonExtractor.extract(ctx)

      types = Enum.map(lesson.evidence_refs, & &1["type"])
      assert "repair" in types
      assert "error_log" in types
    end

    test "falls back to context session_id when repair has none" do
      ctx =
        repair_context(%{
          repair_overrides: %{session_id: nil},
          session_id: "ctx_ses_001"
        })

      # Repair.new requires session_id to be nil or binary — nil is fine
      assert {:ok, lesson} = LessonExtractor.extract(ctx)
      assert lesson.session_id == "ctx_ses_001"
    end

    test "rejects non-succeeded repair" do
      {:ok, repair} =
        Repair.new(%{id: "rep_f", error_log_id: "err_001", strategy: :retry, status: :failed})

      assert {:error, :repair_not_succeeded} = LessonExtractor.extract(%{repair: repair})
    end

    test "rejects pending repair" do
      {:ok, repair} =
        Repair.new(%{id: "rep_p", error_log_id: "err_001", strategy: :retry})

      assert {:error, :repair_not_succeeded} = LessonExtractor.extract(%{repair: repair})
    end

    test "rejects missing repair key" do
      assert {:error, :invalid_repair_context} = LessonExtractor.extract(%{})
    end

    test "rejects non-map context" do
      assert {:error, :invalid_repair_context} = LessonExtractor.extract("nope")
    end
  end

  # -- categorize/1 --

  describe "categorize/1" do
    test "categorizes patch repairs as fix_pattern" do
      ctx = repair_context(%{repair_overrides: %{strategy: :patch}})
      assert LessonExtractor.categorize(ctx) == :fix_pattern
    end

    test "categorizes fallback repairs as workaround" do
      ctx = repair_context(%{repair_overrides: %{strategy: :fallback}})
      assert LessonExtractor.categorize(ctx) == :workaround
    end

    test "categorizes human repairs as root_cause" do
      ctx = repair_context(%{repair_overrides: %{strategy: :human, params: %{notes: "fix"}}})
      assert LessonExtractor.categorize(ctx) == :root_cause
    end

    test "categorizes retry repairs as root_cause" do
      ctx = repair_context(%{repair_overrides: %{strategy: :retry, params: %{attempt: 2}}})
      assert LessonExtractor.categorize(ctx) == :root_cause
    end

    test "categorizes config-related patch repairs as configuration" do
      ctx = repair_context(%{repair_overrides: %{strategy: :patch, params: %{config: "db.yml"}}})
      assert LessonExtractor.categorize(ctx) == :configuration
    end

    test "detects config via string key" do
      ctx =
        repair_context(%{
          repair_overrides: %{strategy: :retry, params: %{"environment" => "prod"}}
        })

      assert LessonExtractor.categorize(ctx) == :configuration
    end
  end

  # -- summarize/1 --

  describe "summarize/1" do
    test "includes strategy name in summary" do
      ctx = repair_context()
      summary = LessonExtractor.summarize(ctx)
      assert summary =~ "patch"
      assert summary =~ "succeeded"
    end

    test "includes file reference when present in params" do
      ctx = repair_context(%{repair_overrides: %{params: %{file: "lib/bug.ex"}}})
      summary = LessonExtractor.summarize(ctx)
      assert summary =~ "lib/bug.ex"
    end

    test "includes string-keyed file reference" do
      ctx = repair_context(%{repair_overrides: %{params: %{"file" => "lib/oops.ex"}}})
      summary = LessonExtractor.summarize(ctx)
      assert summary =~ "lib/oops.ex"
    end

    test "produces valid summary without params" do
      ctx = repair_context(%{repair_overrides: %{strategy: :retry, params: nil}})
      summary = LessonExtractor.summarize(ctx)
      assert is_binary(summary)
      assert summary =~ "retry"
    end

    test "produces summary for each strategy" do
      for strategy <- [:patch, :fallback, :retry, :human] do
        ctx = repair_context(%{repair_overrides: %{strategy: strategy, params: nil}})
        summary = LessonExtractor.summarize(ctx)
        assert is_binary(summary)
        assert String.ends_with?(summary, ".")
      end
    end
  end

  # -- should_persist?/1 --

  describe "should_persist?/1" do
    test "returns false for trivial retry with nil params" do
      ctx = repair_context(%{repair_overrides: %{strategy: :retry, params: nil}})
      refute LessonExtractor.should_persist?(ctx)
    end

    test "returns false for trivial retry with empty params" do
      ctx = repair_context(%{repair_overrides: %{strategy: :retry, params: %{}}})
      refute LessonExtractor.should_persist?(ctx)
    end

    test "returns true for retry with meaningful params" do
      ctx = repair_context(%{repair_overrides: %{strategy: :retry, params: %{attempt: 3}}})
      assert LessonExtractor.should_persist?(ctx)
    end

    test "returns true for patch repairs" do
      ctx = repair_context()
      assert LessonExtractor.should_persist?(ctx)
    end

    test "returns true for fallback repairs" do
      ctx = repair_context(%{repair_overrides: %{strategy: :fallback}})
      assert LessonExtractor.should_persist?(ctx)
    end

    test "returns true for human repairs even with empty params" do
      ctx = repair_context(%{repair_overrides: %{strategy: :human, params: %{}}})
      assert LessonExtractor.should_persist?(ctx)
    end

    test "returns false for invalid context" do
      refute LessonExtractor.should_persist?(%{})
      refute LessonExtractor.should_persist?("nope")
    end
  end

  # -- categories/0 --

  describe "categories/0" do
    test "returns all valid categories" do
      assert LessonExtractor.categories() == [
               :fix_pattern,
               :root_cause,
               :workaround,
               :configuration
             ]
    end
  end
end
