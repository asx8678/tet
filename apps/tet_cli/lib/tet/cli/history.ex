defmodule Tet.CLI.History do
  @moduledoc """
  Fuzzy history search for prompt history entries.

  Searches through Prompt Lab history entries using substring and fuzzy matching.
  This is a pure read-only UX feature — it does not alter runtime policy,
  write to the store, or modify any entries.
  """

  alias Tet.PromptLab.HistoryEntry

  @default_limit 20

  @doc """
  Searches prompt history entries matching the given query.

  Returns `{:ok, entries}` with matching entries sorted by relevance
  (exact > substring > fuzzy), newest first within each tier.

  Options:
  - `:limit` — max results (default 20)
  - `:mode` — `:substring` (default) or `:fuzzy`

  This function calls `Tet.list_prompt_history/1` and filters in-memory.
  It does not modify store data or alter runtime policy.
  """
  @spec search(String.t(), keyword()) :: {:ok, [HistoryEntry.t()]} | {:error, term()}
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    mode = Keyword.get(opts, :mode, :substring)

    with {:ok, entries} <- Tet.list_prompt_history(opts) do
      results =
        entries
        |> Enum.filter(&matches?(&1, query, mode))
        |> Enum.sort_by(&relevance_score(&1, query, mode), :desc)
        |> Enum.take(limit)

      {:ok, results}
    end
  end

  @doc """
  Pure function: checks if a history entry matches the query.

  Mode `:substring` requires the query to appear as a contiguous
  substring of the entry's prompt text.

  Mode `:fuzzy` matches if all characters of the query appear
  in order within the prompt text (subsequence matching).
  """
  @spec matches?(HistoryEntry.t(), String.t(), :substring | :fuzzy) :: boolean()
  def matches?(%HistoryEntry{} = entry, query, mode) when is_binary(query) do
    text = prompt_text(entry)
    normalized_query = String.downcase(query)
    normalized_text = String.downcase(text)

    case mode do
      :substring -> String.contains?(normalized_text, normalized_query)
      :fuzzy -> fuzzy_match?(normalized_text, normalized_query)
    end
  end

  def matches?(_entry, "", _mode), do: true

  @doc """
  Returns a relevance score for ranking. Higher is better.

  Exact match on prompt text gets the highest score, followed by
  substring match position (earlier = better), followed by fuzzy
  match quality.
  """
  @spec relevance_score(HistoryEntry.t(), String.t(), :substring | :fuzzy) :: float()
  def relevance_score(%HistoryEntry{} = entry, query, mode) do
    text = prompt_text(entry)
    normalized_query = String.downcase(query)
    normalized_text = String.downcase(text)

    cond do
      normalized_text == normalized_query ->
        3.0 + recency_bonus(entry)

      mode == :substring and String.contains?(normalized_text, normalized_query) ->
        pos = substring_position(normalized_text, normalized_query)
        substring_score = 2.0 - pos * 0.001
        substring_score + recency_bonus(entry)

      mode == :fuzzy ->
        fuzzy_score = fuzzy_score(normalized_text, normalized_query)
        fuzzy_score + recency_bonus(entry)

      true ->
        0.0
    end
  end

  @doc "Extracts prompt text from a history entry."
  @spec prompt_text(HistoryEntry.t()) :: String.t()
  def prompt_text(%HistoryEntry{request: %Tet.PromptLab.Request{prompt: prompt}}),
    do: prompt || ""

  def prompt_text(_entry), do: ""

  @doc "Renders history entries as a CLI-friendly string."
  @spec render([HistoryEntry.t()]) :: String.t()
  def render([]), do: "No matching history entries."

  def render(entries) when is_list(entries) do
    lines =
      entries
      |> Enum.map(&render_entry/1)

    Enum.join(["History entries:" | lines], "\n")
  end

  defp render_entry(%HistoryEntry{} = entry) do
    prompt = prompt_text(entry) |> preview()
    "  #{entry.id}  #{entry.created_at || "n/a"}  #{prompt}"
  end

  # -- Fuzzy matching (subsequence match) --

  defp fuzzy_match?(_text, ""), do: true

  defp fuzzy_match?(text, query) do
    fuzzy_loop(String.graphemes(query), String.graphemes(text))
  end

  defp fuzzy_loop([], _remaining_text), do: true

  defp fuzzy_loop(_query_chars, []), do: false

  defp fuzzy_loop([q | q_rest], [t | t_rest]) do
    if String.downcase(q) == String.downcase(t) do
      fuzzy_loop(q_rest, t_rest)
    else
      fuzzy_loop([q | q_rest], t_rest)
    end
  end

  defp fuzzy_score(text, query) do
    # Score based on span (first to last match distance), gaps, and contiguous runs.
    # Lower span = better. More contiguous = better.
    graphemes = String.graphemes(query)
    chars = String.graphemes(text)

    {positions, _search_from} =
      Enum.reduce(graphemes, {[], 0}, fn char, {positions, search_from} ->
        lower_char = String.downcase(char)
        remaining = Enum.drop(chars, search_from)

        case Enum.find_index(remaining, &(&1 == lower_char)) do
          nil -> {positions, search_from}
          idx -> {[search_from + idx | positions], search_from + idx + 1}
        end
      end)

    case Enum.reverse(positions) do
      [] ->
        0.0

      [_single] ->
        1.0

      pos_list ->
        [first | _] = pos_list
        last = List.last(pos_list)
        span = last - first + 1
        matched = length(pos_list)

        # Reward short spans (tight match)
        span_score = matched / span

        # Reward contiguous runs and penalize gaps
        {contiguous, gaps} =
          Enum.reduce(pos_list, {0, 0}, fn pos, {cont, gaps} ->
            case pos do
              ^first -> {cont, gaps}
              p -> if (p - 1) in pos_list, do: {cont + 1, gaps}, else: {cont, gaps + 1}
            end
          end)

        # contiguous = number of matched chars that follow a previous match (max: matched-1)
        # gaps = number of matched chars that DON'T follow a previous match
        cont_bonus = contiguous * 0.1
        gap_penalty = gaps * 0.05

        max(0.0, span_score + cont_bonus - gap_penalty)
    end
  end

  defp recency_bonus(%HistoryEntry{created_at: nil}), do: 0.0

  defp recency_bonus(%HistoryEntry{created_at: created_at}) do
    # Newer entries get a tiny tiebreaker bonus, never enough
    # to override match quality. Max ~0.05 over a 5-year range.
    case DateTime.from_iso8601(created_at) do
      {:ok, dt, _offset} ->
        base = ~U[2020-01-01 00:00:00Z]
        seconds = DateTime.diff(dt, base, :second)
        seconds * 0.000000001

      _ ->
        0.0
    end
  end

  defp substring_position(text, query) do
    case :binary.match(text, query) do
      {pos, _len} -> pos
      :nomatch -> 0
    end
  end

  defp preview(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 80)
  end
end
