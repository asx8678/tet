defmodule Tet.ProjectLesson do
  @moduledoc """
  Project Lesson struct — BD-0036.

  Project Lessons are durable, project-wide lessons promoted from findings.
  Unlike Persistent Memory entries (session-scoped), Project Lessons capture
  cross-session patterns such as recurring errors, project conventions,
  successful repair strategies, and verification outcomes.

  Each lesson preserves the provenance chain: the original finding ID,
  the source session, and the promotion timestamp ensure full auditability.
  Lessons are promoted only with evidence and source event references.

  This module is pure data and pure functions. It does not touch the
  filesystem, persist events, or dispatch tools.
  """

  alias Tet.Entity

  @categories [
    :convention,
    :repair_strategy,
    :error_pattern,
    :verification,
    :performance,
    :security
  ]
  @enforce_keys [:id, :title, :source_finding_id]
  defstruct [
    :id,
    :title,
    :description,
    :category,
    :source_finding_id,
    :session_id,
    :evidence_refs,
    :promoted_at,
    :created_at,
    metadata: %{}
  ]

  @type category ::
          :convention
          | :repair_strategy
          | :error_pattern
          | :verification
          | :performance
          | :security
  @type t :: %__MODULE__{
          id: binary(),
          title: binary(),
          description: binary() | nil,
          category: category() | nil,
          source_finding_id: binary(),
          session_id: binary() | nil,
          evidence_refs: [map()] | nil,
          promoted_at: DateTime.t() | nil,
          created_at: DateTime.t() | nil,
          metadata: map()
        }

  @doc "Returns valid lesson categories."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "Builds a validated project lesson from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :project_lesson),
         {:ok, title} <- Entity.fetch_required_binary(attrs, :title, :project_lesson),
         {:ok, description} <- Entity.fetch_optional_binary(attrs, :description, :project_lesson),
         {:ok, category} <- fetch_category(attrs),
         {:ok, source_finding_id} <-
           Entity.fetch_required_binary(attrs, :source_finding_id, :project_lesson),
         {:ok, session_id} <- Entity.fetch_optional_binary(attrs, :session_id, :project_lesson),
         {:ok, evidence_refs} <- fetch_optional_list(attrs, :evidence_refs),
         {:ok, promoted_at} <-
           Entity.fetch_optional_datetime(attrs, :promoted_at, :project_lesson),
         {:ok, created_at} <- Entity.fetch_optional_datetime(attrs, :created_at, :project_lesson),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :project_lesson) do
      {:ok,
       %__MODULE__{
         id: id,
         title: title,
         description: description,
         category: category,
         source_finding_id: source_finding_id,
         session_id: session_id,
         evidence_refs: evidence_refs,
         promoted_at: promoted_at,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_project_lesson}

  @doc "Converts a project lesson to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = lesson) do
    %{
      id: lesson.id,
      title: lesson.title,
      source_finding_id: lesson.source_finding_id
    }
    |> maybe_put(:description, lesson.description)
    |> maybe_put(:category, Entity.atom_to_map(lesson.category))
    |> maybe_put(:session_id, lesson.session_id)
    |> maybe_put(:evidence_refs, lesson.evidence_refs)
    |> maybe_put(:promoted_at, Entity.datetime_to_map(lesson.promoted_at))
    |> maybe_put(:created_at, Entity.datetime_to_map(lesson.created_at))
    |> Map.put(:metadata, lesson.metadata)
  end

  @doc "Converts a decoded map back to a validated project lesson."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Private helpers --

  defp fetch_category(attrs) do
    case Entity.fetch_value(attrs, :category) do
      nil ->
        {:ok, nil}

      category when category in @categories ->
        {:ok, category}

      category when is_binary(category) ->
        case Enum.find(@categories, &(Atom.to_string(&1) == category)) do
          nil -> {:error, {:invalid_project_lesson_field, :category}}
          atom -> {:ok, atom}
        end

      _ ->
        {:error, {:invalid_project_lesson_field, :category}}
    end
  end

  defp fetch_optional_list(attrs, key) do
    case Entity.fetch_value(attrs, key) do
      nil -> {:ok, nil}
      value when is_list(value) -> {:ok, value}
      _ -> {:error, {:invalid_project_lesson_field, key}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
