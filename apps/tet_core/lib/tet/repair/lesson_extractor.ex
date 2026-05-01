defmodule Tet.Repair.LessonExtractor do
  @moduledoc """
  Extracts project lessons from completed repair workflows — BD-0062.

  After a repair succeeds, the extractor analyses the repair context
  to produce a `Tet.ProjectLesson` struct capturing what was learned.
  This feeds into the project knowledge base for future reference.

  Not every repair is lesson-worthy. Trivial retries (simple transient
  failures with no meaningful params) are filtered out by `should_persist?/1`.

  This module is pure data and pure functions. It does not touch the
  filesystem, persist events, or dispatch tools.
  """

  alias Tet.{ProjectLesson, Repair}

  @categories [:fix_pattern, :root_cause, :workaround, :configuration]

  @type category :: :fix_pattern | :root_cause | :workaround | :configuration
  @type repair_context :: %{
          required(:repair) => Repair.t(),
          optional(:session_id) => binary(),
          optional(:checkpoint_id) => binary()
        }

  @doc "Returns valid lesson extractor categories."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc """
  Extracts a `Tet.ProjectLesson` from a completed repair workflow context.

  The context map must include a `:repair` key holding a succeeded
  `Tet.Repair` struct. Returns `{:error, :repair_not_succeeded}` when the
  repair has not reached the `:succeeded` status.
  """
  @spec extract(repair_context()) :: {:ok, ProjectLesson.t()} | {:error, term()}
  def extract(%{repair: %Repair{status: :succeeded} = repair} = context) do
    category = categorize(context)
    summary = summarize(context)

    ProjectLesson.new(%{
      id: "les_" <> repair.id,
      title: "Repair lesson: #{repair.strategy}",
      description: summary,
      category: map_to_project_category(category),
      source_finding_id: repair.error_log_id,
      session_id: repair.session_id || Map.get(context, :session_id),
      evidence_refs: build_evidence_refs(context),
      created_at: DateTime.utc_now(),
      metadata: %{
        "repair_id" => repair.id,
        "repair_strategy" => Atom.to_string(repair.strategy),
        "extractor_category" => Atom.to_string(category),
        "source" => "lesson_extractor"
      }
    })
  end

  def extract(%{repair: %Repair{}}), do: {:error, :repair_not_succeeded}
  def extract(_), do: {:error, :invalid_repair_context}

  @doc """
  Categorises the lesson derived from a repair context.

  Mapping rules:

    * Config-related params → `:configuration`
    * `:patch` strategy     → `:fix_pattern`
    * `:fallback` strategy  → `:workaround`
    * `:human` strategy     → `:root_cause`
    * `:retry` strategy     → `:root_cause`
  """
  @spec categorize(repair_context()) :: category()
  def categorize(%{repair: %Repair{} = repair}) do
    cond do
      configuration_repair?(repair) -> :configuration
      repair.strategy == :patch -> :fix_pattern
      repair.strategy == :fallback -> :workaround
      repair.strategy in [:human, :retry] -> :root_cause
      true -> :fix_pattern
    end
  end

  @doc "Generates a human-readable summary from the repair context."
  @spec summarize(repair_context()) :: binary()
  def summarize(%{repair: %Repair{} = repair}) do
    base = "Repair #{repair.id} succeeded via #{repair.strategy} strategy"
    base <> strategy_detail(repair.strategy) <> file_detail(repair.params) <> "."
  end

  @doc """
  Determines whether a repair lesson is worth persisting.

  Simple retries without meaningful params (trivial transient failures) are
  not worth persisting. Everything else captures useful project knowledge.
  """
  @spec should_persist?(repair_context()) :: boolean()
  def should_persist?(%{repair: %Repair{strategy: :retry, params: nil}}), do: false

  def should_persist?(%{repair: %Repair{strategy: :retry, params: params}})
      when map_size(params) == 0,
      do: false

  def should_persist?(%{repair: %Repair{}}), do: true
  def should_persist?(_), do: false

  # -- Private helpers --

  @config_keys ~w(config configuration env environment setting)

  defp configuration_repair?(%Repair{params: params}) when is_map(params) do
    params
    |> Map.keys()
    |> Enum.any?(fn key ->
      key_str = if is_atom(key), do: Atom.to_string(key), else: to_string(key)
      key_str in @config_keys
    end)
  end

  defp configuration_repair?(_repair), do: false

  defp map_to_project_category(:fix_pattern), do: :repair_strategy
  defp map_to_project_category(:root_cause), do: :error_pattern
  defp map_to_project_category(:workaround), do: :repair_strategy
  defp map_to_project_category(:configuration), do: :convention

  defp strategy_detail(:patch), do: " by applying a code patch"
  defp strategy_detail(:fallback), do: " using a fallback approach"
  defp strategy_detail(:retry), do: " after retrying the operation"
  defp strategy_detail(:human), do: " with human intervention"

  defp file_detail(%{file: file}) when is_binary(file), do: " on #{file}"
  defp file_detail(%{"file" => file}) when is_binary(file), do: " on #{file}"
  defp file_detail(_params), do: ""

  defp build_evidence_refs(%{repair: repair} = context) do
    [%{"type" => "repair", "id" => repair.id}]
    |> maybe_append_ref(repair.error_log_id, "error_log")
    |> maybe_append_ref(Map.get(context, :checkpoint_id), "checkpoint")
  end

  defp maybe_append_ref(refs, nil, _type), do: refs
  defp maybe_append_ref(refs, id, type), do: refs ++ [%{"type" => type, "id" => id}]
end
