defmodule Tet.Finding do
  @moduledoc """
  Finding struct for structured observations — BD-0036.

  Findings are evidence-backed observations extracted from events, tools,
  failures, reviews, and verifiers. They live in the Finding Store until
  promoted to Persistent Memory or Project Lessons.

  A finding records what was observed, its source, severity, and optional
  evidence references (event IDs, tool run IDs, artifact IDs). Findings
  are deduplicated and scored before promotion.

  This module is pure data and pure functions. It does not dispatch tools,
  touch the filesystem, or persist events.
  """

  alias Tet.Entity

  @statuses [:open, :promoted, :dismissed]
  @severities [:info, :warning, :critical]
  @sources [:event, :tool_run, :failure, :review, :verifier, :repair, :manual]

  @enforce_keys [:id, :session_id, :title, :source]
  defstruct [
    :id,
    :session_id,
    :task_id,
    :title,
    :description,
    :source,
    :severity,
    :evidence_refs,
    :promoted_to,
    :promoted_at,
    status: :open,
    created_at: nil,
    metadata: %{}
  ]

  @type status :: :open | :promoted | :dismissed
  @type severity :: :info | :warning | :critical
  @type source :: :event | :tool_run | :failure | :review | :verifier | :repair | :manual
  @type promotion_target :: {:persistent_memory, binary()} | {:project_lesson, binary()}
  @type t :: %__MODULE__{
          id: binary(),
          session_id: binary(),
          task_id: binary() | nil,
          title: binary(),
          description: binary() | nil,
          source: source(),
          severity: severity(),
          evidence_refs: [map()] | nil,
          promoted_to: promotion_target() | nil,
          promoted_at: DateTime.t() | nil,
          status: status(),
          created_at: DateTime.t() | nil,
          metadata: map()
        }

  @doc "Returns valid finding statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns valid finding severities."
  @spec severities() :: [severity()]
  def severities, do: @severities

  @doc "Returns valid finding sources."
  @spec sources() :: [source()]
  def sources, do: @sources

  @doc "Builds a validated finding from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :finding),
         {:ok, session_id} <- Entity.fetch_required_binary(attrs, :session_id, :finding),
         {:ok, task_id} <- Entity.fetch_optional_binary(attrs, :task_id, :finding),
         {:ok, title} <- Entity.fetch_required_binary(attrs, :title, :finding),
         {:ok, description} <- Entity.fetch_optional_binary(attrs, :description, :finding),
         {:ok, source} <- fetch_source(attrs),
         {:ok, severity} <- fetch_severity(attrs, :severity, :info),
         {:ok, evidence_refs} <- fetch_optional_list(attrs, :evidence_refs),
         {:ok, promoted_to} <- fetch_optional_promoted_to(attrs),
         {:ok, promoted_at} <- Entity.fetch_optional_datetime(attrs, :promoted_at, :finding),
         {:ok, status} <- fetch_status(attrs, :status, :open),
         {:ok, created_at} <- Entity.fetch_optional_datetime(attrs, :created_at, :finding),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :finding) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         task_id: task_id,
         title: title,
         description: description,
         source: source,
         severity: severity,
         evidence_refs: evidence_refs,
         promoted_to: promoted_to,
         promoted_at: promoted_at,
         status: status,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_finding}

  @doc "Promotes a finding, recording the target and timestamp."
  @spec promote(t(), promotion_target(), DateTime.t()) :: t()
  def promote(%__MODULE__{} = finding, {type, target_id} = _target, %DateTime{} = promoted_at)
      when type in [:persistent_memory, :project_lesson] do
    %__MODULE__{
      finding
      | status: :promoted,
        promoted_to: {type, target_id},
        promoted_at: promoted_at
    }
  end

  @doc "Dismisses a finding, setting status to :dismissed."
  @spec dismiss(t()) :: t()
  def dismiss(%__MODULE__{} = finding) do
    %__MODULE__{finding | status: :dismissed}
  end

  @doc "Converts a finding to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = finding) do
    %{
      id: finding.id,
      session_id: finding.session_id,
      title: finding.title,
      source: Entity.atom_to_map(finding.source),
      severity: Entity.atom_to_map(finding.severity),
      status: Atom.to_string(finding.status)
    }
    |> maybe_put(:task_id, finding.task_id)
    |> maybe_put(:description, finding.description)
    |> maybe_put(:evidence_refs, finding.evidence_refs)
    |> maybe_put(:promoted_to, format_promoted_to(finding.promoted_to))
    |> maybe_put(:promoted_at, Entity.datetime_to_map(finding.promoted_at))
    |> maybe_put(:created_at, Entity.datetime_to_map(finding.created_at))
    |> Map.put(:metadata, finding.metadata)
  end

  @doc "Converts a decoded map back to a validated finding."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Private helpers --

  defp fetch_source(attrs) do
    Entity.fetch_atom(attrs, :source, @sources, :finding)
  end

  defp fetch_severity(attrs, key, default) do
    case Entity.fetch_value(attrs, key, default) do
      severity when severity in @severities -> {:ok, severity}
      severity when is_atom(severity) -> {:error, {:invalid_finding_field, key}}
      severity when is_binary(severity) -> parse_enum(severity, @severities, key)
      _ -> {:error, {:invalid_finding_field, key}}
    end
  end

  defp fetch_status(attrs, key, default) do
    case Entity.fetch_value(attrs, key, default) do
      status when status in @statuses -> {:ok, status}
      status when is_atom(status) -> {:error, {:invalid_finding_field, key}}
      status when is_binary(status) -> parse_enum(status, @statuses, key)
      _ -> {:error, {:invalid_finding_field, key}}
    end
  end

  defp fetch_optional_list(attrs, key) do
    case Entity.fetch_value(attrs, key) do
      nil -> {:ok, nil}
      value when is_list(value) -> {:ok, value}
      _ -> {:error, {:invalid_finding_field, key}}
    end
  end

  defp fetch_optional_promoted_to(attrs) do
    case Entity.fetch_value(attrs, :promoted_to) do
      nil ->
        {:ok, nil}

      {type, id} when type in [:persistent_memory, :project_lesson] and is_binary(id) ->
        {:ok, {type, id}}

      # String-keyed nested map (from JSON decode): %{"type" => "persistent_memory", "id" => "pm_001"}
      %{"type" => type_str, "id" => id} when is_binary(type_str) and is_binary(id) ->
        decode_promoted_to(type_str, id)

      # Atom-keyed nested map (from to_map round-trip): %{type: "persistent_memory", id: "pm_001"}
      %{type: type_str, id: id} when is_binary(type_str) and is_binary(id) ->
        decode_promoted_to(type_str, id)

      _ ->
        {:error, {:invalid_finding_field, :promoted_to}}
    end
  end

  defp decode_promoted_to("persistent_memory", id), do: {:ok, {:persistent_memory, id}}
  defp decode_promoted_to("project_lesson", id), do: {:ok, {:project_lesson, id}}
  defp decode_promoted_to(_, _), do: {:error, {:invalid_finding_field, :promoted_to}}

  defp parse_enum(str, allowed, key) when is_binary(str) do
    case Enum.find(allowed, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_finding_field, key}}
      atom -> {:ok, atom}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_promoted_to(nil), do: nil
  defp format_promoted_to({type, id}), do: %{type: Atom.to_string(type), id: id}
end
