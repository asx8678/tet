defmodule Tet.FindingStore do
  @moduledoc """
  Finding Store, Persistent Memory, and Project Lessons facade — BD-0036.

  Wraps a `Tet.Store` adapter to provide focused finding, persistent memory,
  and project lesson operations. Callers pass the store module (defaulting to
  the configured `:tet_core, :store_adapter`) so the adapter seam remains
  explicit and testable without crossing the core↔runtime architecture boundary.

  ## Promotion flow

  Findings are captured as structured observations. When a finding is valuable
  enough for durable retention, it can be promoted to:

  - **Persistent Memory** — session-scoped, evidence-backed observations that
    persist across sessions.
  - **Project Lessons** — project-wide lessons from recurring patterns,
    successful repairs, project conventions, and verification outcomes.

  Each promotion:

  1. Creates the target entry (Persistent Memory or Project Lesson)
  2. Updates the finding's status to `:promoted` with a `promoted_to` reference
  3. Emits an audit event for traceability

  This module does **not** define its own process or storage — it delegates
  everything to the underlying `Tet.Store` behaviour implementation.
  """

  @promotion_targets [:persistent_memory, :project_lesson]

  # -- Finding operations --

  @doc """
  Records a new finding via the store adapter.

  Returns `{:ok, Tet.Finding.t()}` on success.
  """
  @spec record_finding(map(), keyword()) :: {:ok, Tet.Finding.t()} | {:error, term()}
  def record_finding(attrs) when is_map(attrs),
    do: record_finding(default_store(), attrs, [])

  def record_finding(attrs, opts) when is_map(attrs) and is_list(opts),
    do: record_finding(default_store(), attrs, opts)

  def record_finding(store, attrs) when is_atom(store) and is_map(attrs),
    do: record_finding(store, attrs, [])

  def record_finding(store, attrs, opts)
      when is_atom(store) and is_map(attrs) and is_list(opts) do
    attrs = Tet.Store.Helpers.ensure_created_at(attrs)

    with {:ok, finding} <- store.record_finding(attrs, opts),
         event = build_finding_created_event(finding),
         {:ok, _} <- store.append_event(Tet.Event.to_map(event), opts) do
      {:ok, finding}
    end
  end

  @doc "Fetches a single finding by id."
  @spec get_finding(String.t(), keyword()) :: {:ok, Tet.Finding.t()} | {:error, term()}
  def get_finding(finding_id) when is_binary(finding_id),
    do: get_finding(default_store(), finding_id, [])

  def get_finding(finding_id, opts) when is_binary(finding_id) and is_list(opts),
    do: get_finding(default_store(), finding_id, opts)

  def get_finding(store, finding_id) when is_atom(store) and is_binary(finding_id),
    do: get_finding(store, finding_id, [])

  def get_finding(store, finding_id, opts)
      when is_atom(store) and is_binary(finding_id) and is_list(opts) do
    store.get_finding(finding_id, opts)
  end

  @doc "Lists findings for a session."
  @spec list_findings(String.t(), keyword()) :: {:ok, [Tet.Finding.t()]} | {:error, term()}
  def list_findings(session_id) when is_binary(session_id),
    do: list_findings(default_store(), session_id, [])

  def list_findings(session_id, opts) when is_binary(session_id) and is_list(opts),
    do: list_findings(default_store(), session_id, opts)

  def list_findings(store, session_id) when is_atom(store) and is_binary(session_id),
    do: list_findings(store, session_id, [])

  def list_findings(store, session_id, opts)
      when is_atom(store) and is_binary(session_id) and is_list(opts) do
    store.list_findings(session_id, opts)
  end

  @doc "Updates a finding entry."
  @spec update_finding(String.t(), map(), keyword()) ::
          {:ok, Tet.Finding.t()} | {:error, term()}
  def update_finding(finding_id, attrs) when is_binary(finding_id) and is_map(attrs),
    do: update_finding(default_store(), finding_id, attrs, [])

  def update_finding(finding_id, attrs, opts)
      when is_binary(finding_id) and is_map(attrs) and is_list(opts),
      do: update_finding(default_store(), finding_id, attrs, opts)

  def update_finding(store, finding_id, attrs)
      when is_atom(store) and is_binary(finding_id) and is_map(attrs),
      do: update_finding(store, finding_id, attrs, [])

  def update_finding(store, finding_id, attrs, opts)
      when is_atom(store) and is_binary(finding_id) and is_map(attrs) and is_list(opts) do
    store.update_finding(finding_id, attrs, opts)
  end

  # -- Promotion: Finding → Persistent Memory --

  @doc """
  Promotes a finding to Persistent Memory.

  Creates a Persistent Memory entry, updates the finding status to
  `:promoted`, and emits a `finding.promoted_to_persistent_memory` audit event.

  Returns `{:ok, {Tet.Finding.t(), Tet.PersistentMemory.t()}}` on success.

  ## Options

  - `:metadata` — additional metadata for the persistent memory entry
  """
  @spec promote_to_persistent_memory(String.t(), keyword()) ::
          {:ok, {Tet.Finding.t(), Tet.PersistentMemory.t()}} | {:error, term()}
  def promote_to_persistent_memory(finding_id, opts \\ [])
      when is_binary(finding_id) and is_list(opts) do
    promote_to_persistent_memory(default_store(), finding_id, opts)
  end

  def promote_to_persistent_memory(store, finding_id, opts)
      when is_atom(store) and is_binary(finding_id) and is_list(opts) do
    store.transaction(fn ->
      with {:ok, finding} <- store.get_finding(finding_id, opts),
           :ok <- validate_promotable(finding),
           pm_attrs <- build_persistent_memory_attrs(finding, opts),
           {:ok, pm_entry} <- store.store_persistent_memory(pm_attrs, opts),
           now = DateTime.utc_now(),
           updated_finding = Tet.Finding.promote(finding, {:persistent_memory, pm_entry.id}, now),
           {:ok, _} <- store.update_finding(finding_id, Map.from_struct(updated_finding), opts),
           event = build_promoted_to_persistent_memory_event(updated_finding, pm_entry),
           {:ok, _} <- store.append_event(Tet.Event.to_map(event), opts) do
        {:ok, {updated_finding, pm_entry}}
      end
    end)
  end

  # -- Promotion: Finding → Project Lesson --

  @doc """
  Promotes a finding to a Project Lesson.

  Creates a Project Lesson entry, updates the finding status to
  `:promoted`, and emits a `finding.promoted_to_project_lesson` audit event.

  Returns `{:ok, {Tet.Finding.t(), Tet.ProjectLesson.t()}}` on success.

  ## Options

  - `:category` — lesson category (see `Tet.ProjectLesson.categories/0`)
  - `:metadata` — additional metadata for the project lesson entry
  """
  @spec promote_to_project_lesson(String.t(), keyword()) ::
          {:ok, {Tet.Finding.t(), Tet.ProjectLesson.t()}} | {:error, term()}
  def promote_to_project_lesson(finding_id, opts \\ [])
      when is_binary(finding_id) and is_list(opts) do
    promote_to_project_lesson(default_store(), finding_id, opts)
  end

  def promote_to_project_lesson(store, finding_id, opts)
      when is_atom(store) and is_binary(finding_id) and is_list(opts) do
    store.transaction(fn ->
      with {:ok, finding} <- store.get_finding(finding_id, opts),
           :ok <- validate_promotable(finding),
           lesson_attrs <- build_project_lesson_attrs(finding, opts),
           {:ok, lesson} <- store.store_project_lesson(lesson_attrs, opts),
           now = DateTime.utc_now(),
           updated_finding = Tet.Finding.promote(finding, {:project_lesson, lesson.id}, now),
           {:ok, _} <- store.update_finding(finding_id, Map.from_struct(updated_finding), opts),
           event = build_promoted_to_project_lesson_event(updated_finding, lesson),
           {:ok, _} <- store.append_event(Tet.Event.to_map(event), opts) do
        {:ok, {updated_finding, lesson}}
      end
    end)
  end

  # -- Dismiss finding --

  @doc """
  Dismisses a finding, setting its status to `:dismissed`.

  Returns `{:ok, Tet.Finding.t()}` on success.
  """
  @spec dismiss_finding(String.t(), keyword()) ::
          {:ok, Tet.Finding.t()} | {:error, term()}
  def dismiss_finding(finding_id) when is_binary(finding_id),
    do: dismiss_finding(default_store(), finding_id, [])

  def dismiss_finding(finding_id, opts) when is_binary(finding_id) and is_list(opts),
    do: dismiss_finding(default_store(), finding_id, opts)

  def dismiss_finding(store, finding_id) when is_atom(store) and is_binary(finding_id),
    do: dismiss_finding(store, finding_id, [])

  def dismiss_finding(store, finding_id, opts)
      when is_atom(store) and is_binary(finding_id) and is_list(opts) do
    store.transaction(fn ->
      with {:ok, finding} <- store.get_finding(finding_id, opts),
           :ok <- validate_dismissable(finding),
           dismissed = Tet.Finding.dismiss(finding),
           {:ok, _} <- store.update_finding(finding_id, Map.from_struct(dismissed), opts),
           event = build_finding_dismissed_event(dismissed),
           {:ok, _} <- store.append_event(Tet.Event.to_map(event), opts) do
        {:ok, dismissed}
      end
    end)
  end

  # -- Persistent Memory operations --

  @doc "Stores a persistent memory entry."
  @spec store_persistent_memory(map(), keyword()) ::
          {:ok, Tet.PersistentMemory.t()} | {:error, term()}
  def store_persistent_memory(attrs) when is_map(attrs),
    do: store_persistent_memory(default_store(), attrs, [])

  def store_persistent_memory(attrs, opts) when is_map(attrs) and is_list(opts),
    do: store_persistent_memory(default_store(), attrs, opts)

  def store_persistent_memory(store, attrs) when is_atom(store) and is_map(attrs),
    do: store_persistent_memory(store, attrs, [])

  def store_persistent_memory(store, attrs, opts)
      when is_atom(store) and is_map(attrs) and is_list(opts) do
    attrs = Tet.Store.Helpers.ensure_created_at(attrs)
    store.store_persistent_memory(attrs, opts)
  end

  @doc "Fetches a single persistent memory entry by id."
  @spec get_persistent_memory(String.t(), keyword()) ::
          {:ok, Tet.PersistentMemory.t()} | {:error, term()}
  def get_persistent_memory(pm_id) when is_binary(pm_id),
    do: get_persistent_memory(default_store(), pm_id, [])

  def get_persistent_memory(pm_id, opts) when is_binary(pm_id) and is_list(opts),
    do: get_persistent_memory(default_store(), pm_id, opts)

  def get_persistent_memory(store, pm_id) when is_atom(store) and is_binary(pm_id),
    do: get_persistent_memory(store, pm_id, [])

  def get_persistent_memory(store, pm_id, opts)
      when is_atom(store) and is_binary(pm_id) and is_list(opts) do
    store.get_persistent_memory(pm_id, opts)
  end

  @doc "Lists persistent memory entries for a session."
  @spec list_persistent_memories(String.t(), keyword()) ::
          {:ok, [Tet.PersistentMemory.t()]} | {:error, term()}
  def list_persistent_memories(session_id) when is_binary(session_id),
    do: list_persistent_memories(default_store(), session_id, [])

  def list_persistent_memories(session_id, opts)
      when is_binary(session_id) and is_list(opts),
      do: list_persistent_memories(default_store(), session_id, opts)

  def list_persistent_memories(store, session_id)
      when is_atom(store) and is_binary(session_id),
      do: list_persistent_memories(store, session_id, [])

  def list_persistent_memories(store, session_id, opts)
      when is_atom(store) and is_binary(session_id) and is_list(opts) do
    store.list_persistent_memories(session_id, opts)
  end

  # -- Project Lesson operations --

  @doc "Stores a project lesson entry."
  @spec store_project_lesson(map(), keyword()) ::
          {:ok, Tet.ProjectLesson.t()} | {:error, term()}
  def store_project_lesson(attrs) when is_map(attrs),
    do: store_project_lesson(default_store(), attrs, [])

  def store_project_lesson(attrs, opts) when is_map(attrs) and is_list(opts),
    do: store_project_lesson(default_store(), attrs, opts)

  def store_project_lesson(store, attrs) when is_atom(store) and is_map(attrs),
    do: store_project_lesson(store, attrs, [])

  def store_project_lesson(store, attrs, opts)
      when is_atom(store) and is_map(attrs) and is_list(opts) do
    attrs = Tet.Store.Helpers.ensure_created_at(attrs)
    store.store_project_lesson(attrs, opts)
  end

  @doc "Fetches a single project lesson by id."
  @spec get_project_lesson(String.t(), keyword()) ::
          {:ok, Tet.ProjectLesson.t()} | {:error, term()}
  def get_project_lesson(lesson_id) when is_binary(lesson_id),
    do: get_project_lesson(default_store(), lesson_id, [])

  def get_project_lesson(lesson_id, opts) when is_binary(lesson_id) and is_list(opts),
    do: get_project_lesson(default_store(), lesson_id, opts)

  def get_project_lesson(store, lesson_id) when is_atom(store) and is_binary(lesson_id),
    do: get_project_lesson(store, lesson_id, [])

  def get_project_lesson(store, lesson_id, opts)
      when is_atom(store) and is_binary(lesson_id) and is_list(opts) do
    store.get_project_lesson(lesson_id, opts)
  end

  @doc "Lists project lessons, optionally filtered by category."
  @spec list_project_lessons(keyword()) ::
          {:ok, [Tet.ProjectLesson.t()]} | {:error, term()}
  def list_project_lessons(opts \\ []) when is_list(opts),
    do: list_project_lessons(default_store(), opts)

  def list_project_lessons(store, opts) when is_atom(store) and is_list(opts) do
    store.list_project_lessons(opts)
  end

  # -- Audit helpers --

  @doc "Returns the valid promotion targets."
  @spec promotion_targets() :: [atom()]
  def promotion_targets, do: @promotion_targets

  @doc "Builds a finding.created audit event."
  @spec build_finding_created_event(Tet.Finding.t()) :: Tet.Event.t()
  def build_finding_created_event(%Tet.Finding{} = finding) do
    Tet.Event.finding_created(
      %{
        finding_id: finding.id,
        source: finding.source,
        severity: finding.severity,
        title: finding.title
      },
      session_id: finding.session_id
    )
  end

  @doc "Builds a finding.promoted_to_persistent_memory audit event."
  @spec build_promoted_to_persistent_memory_event(Tet.Finding.t(), Tet.PersistentMemory.t()) ::
          Tet.Event.t()
  def build_promoted_to_persistent_memory_event(
        %Tet.Finding{} = finding,
        %Tet.PersistentMemory{} = pm
      ) do
    Tet.Event.finding_promoted_to_persistent_memory(
      %{
        finding_id: finding.id,
        persistent_memory_id: pm.id,
        title: finding.title
      },
      session_id: finding.session_id
    )
  end

  @doc "Builds a finding.promoted_to_project_lesson audit event."
  @spec build_promoted_to_project_lesson_event(Tet.Finding.t(), Tet.ProjectLesson.t()) ::
          Tet.Event.t()
  def build_promoted_to_project_lesson_event(
        %Tet.Finding{} = finding,
        %Tet.ProjectLesson{} = lesson
      ) do
    Tet.Event.finding_promoted_to_project_lesson(
      %{
        finding_id: finding.id,
        project_lesson_id: lesson.id,
        category: lesson.category,
        title: finding.title
      },
      session_id: finding.session_id
    )
  end

  @doc "Builds a finding.dismissed audit event."
  @spec build_finding_dismissed_event(Tet.Finding.t()) :: Tet.Event.t()
  def build_finding_dismissed_event(%Tet.Finding{} = finding) do
    Tet.Event.finding_dismissed(
      %{
        finding_id: finding.id,
        title: finding.title
      },
      session_id: finding.session_id
    )
  end

  # -- Default store adapter --

  defp default_store do
    Application.get_env(:tet_core, :store_adapter, Tet.Store.Memory)
  end

  # -- Promotion validation --

  defp validate_promotable(%Tet.Finding{status: :open}), do: :ok

  defp validate_promotable(%Tet.Finding{status: :promoted}),
    do: {:error, :finding_already_promoted}

  defp validate_promotable(%Tet.Finding{status: :dismissed}),
    do: {:error, :finding_dismissed}

  defp validate_dismissable(%Tet.Finding{status: :open}), do: :ok

  defp validate_dismissable(%Tet.Finding{status: :promoted}),
    do: {:error, :finding_already_promoted}

  defp validate_dismissable(%Tet.Finding{status: :dismissed}),
    do: {:error, :finding_already_dismissed}

  # -- Promotion attribute builders --

  defp build_persistent_memory_attrs(finding, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    %{
      id: generate_persistent_memory_id(finding.id),
      session_id: finding.session_id,
      title: finding.title,
      description: finding.description,
      source_finding_id: finding.id,
      severity: finding.severity,
      evidence_refs: finding.evidence_refs,
      promoted_at: DateTime.utc_now(),
      metadata: Map.merge(finding.metadata, metadata)
    }
  end

  defp build_project_lesson_attrs(finding, opts) do
    category = Keyword.get(opts, :category)
    metadata = Keyword.get(opts, :metadata, %{})

    %{
      id: generate_project_lesson_id(finding.id),
      title: finding.title,
      description: finding.description,
      category: category,
      source_finding_id: finding.id,
      session_id: finding.session_id,
      evidence_refs: finding.evidence_refs,
      promoted_at: DateTime.utc_now(),
      metadata: Map.merge(finding.metadata, metadata)
    }
  end

  defp generate_persistent_memory_id(finding_id) do
    "pm_#{finding_id}"
  end

  defp generate_project_lesson_id(finding_id) do
    "pl_#{finding_id}"
  end
end
