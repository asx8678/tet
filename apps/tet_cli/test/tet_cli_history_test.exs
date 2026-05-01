defmodule Tet.CLI.HistoryTest do
  use ExUnit.Case, async: true

  alias Tet.CLI.History
  alias Tet.PromptLab.HistoryEntry

  describe "matches?/3 substring mode" do
    test "matches when query is a substring of the prompt" do
      entry = history_entry("Implement CLI sessions list")
      assert History.matches?(entry, "CLI sessions", :substring)
    end

    test "matches case-insensitively" do
      entry = history_entry("Implement CLI sessions list")
      assert History.matches?(entry, "cli sessions", :substring)
      assert History.matches?(entry, "IMPLEMENT", :substring)
    end

    test "does not match when query is not a substring" do
      entry = history_entry("Implement CLI sessions list")
      refute History.matches?(entry, "deploy production", :substring)
    end

    test "matches empty query (returns all)" do
      entry = history_entry("anything")
      assert History.matches?(entry, "", :substring)
    end
  end

  describe "matches?/3 fuzzy mode" do
    test "matches when query characters appear in order" do
      entry = history_entry("Implement CLI sessions")
      assert History.matches?(entry, "ICs", :fuzzy)
    end

    test "matches case-insensitively in fuzzy mode" do
      entry = history_entry("Implement CLI sessions")
      assert History.matches?(entry, "ics", :fuzzy)
    end

    test "does not match when query characters are out of order" do
      entry = history_entry("abc")
      refute History.matches?(entry, "cba", :fuzzy)
    end

    test "matches empty query in fuzzy mode" do
      entry = history_entry("anything")
      assert History.matches?(entry, "", :fuzzy)
    end

    test "matches single character" do
      entry = history_entry("hello world")
      assert History.matches?(entry, "h", :fuzzy)
      assert History.matches?(entry, "w", :fuzzy)
    end
  end

  describe "relevance_score/3" do
    test "exact match gets highest score" do
      entry = history_entry("test query")
      score = History.relevance_score(entry, "test query", :substring)
      assert score >= 3.0
    end

    test "substring match gets medium score" do
      entry = history_entry("the test query here")
      score = History.relevance_score(entry, "test query", :substring)
      assert score >= 1.5
      assert score < 3.0
    end

    test "non-matching gets zero score" do
      entry = history_entry("completely different")
      score = History.relevance_score(entry, "test query", :substring)
      assert score == 0.0
    end

    test "fuzzy: contiguous match scores higher than sparse match" do
      # "abc" contiguous in "xabcx" should beat "abc" scattered in "aXXbXXc"
      contiguous_entry = history_entry("xabcx")
      scattered_entry = history_entry("aXXbXXc")

      contiguous_score = History.relevance_score(contiguous_entry, "abc", :fuzzy)
      scattered_score = History.relevance_score(scattered_entry, "abc", :fuzzy)

      assert contiguous_score > scattered_score
    end

    test "fuzzy: shorter span scores higher than longer span" do
      tight_entry = history_entry("abc")
      wide_entry = history_entry("a.....b.....c")

      tight_score = History.relevance_score(tight_entry, "abc", :fuzzy)
      wide_score = History.relevance_score(wide_entry, "abc", :fuzzy)

      assert tight_score > wide_score
    end
  end

  describe "prompt_text/1" do
    test "extracts prompt from history entry" do
      entry = history_entry("my prompt text")
      assert History.prompt_text(entry) == "my prompt text"
    end
  end

  describe "render/1" do
    test "renders empty list with friendly message" do
      assert History.render([]) == "No matching history entries."
    end

    test "renders entries with header" do
      entries = [
        history_entry("first prompt"),
        history_entry("second prompt")
      ]

      rendered = History.render(entries)
      assert rendered =~ "History entries:"
      assert rendered =~ "first prompt"
      assert rendered =~ "second prompt"
    end

    test "truncates long prompts in rendering" do
      long_prompt = String.duplicate("x", 200)
      entries = [history_entry(long_prompt)]

      rendered = History.render(entries)
      # Should be truncated to preview length
      assert rendered =~ "History entries:"
      refute rendered =~ String.duplicate("x", 200)
    end
  end

  # -- Test helpers --

  defp history_entry(prompt) do
    {:ok, refinement} =
      Tet.PromptLab.refine(prompt,
        preset: "coding",
        refinement_id: "refinement-test-#{System.unique_integer([:positive])}"
      )

    {:ok, request} =
      Tet.PromptLab.Request.new(%{
        prompt: prompt,
        preset_id: "coding",
        metadata: %{test: true}
      })

    {:ok, entry} =
      HistoryEntry.new(%{
        id: "test-history-#{System.unique_integer([:positive])}",
        created_at: "2025-01-01T00:00:00.000Z",
        request: request,
        result: refinement,
        metadata: %{test: true}
      })

    entry
  end
end
