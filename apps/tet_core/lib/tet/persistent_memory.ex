defmodule Tet.PersistentMemory do
  @moduledoc """
  Persistent Memory entry struct — BD-0036.

  Persistent Memory stores promoted findings that are durable across
  sessions. These are evidence-backed observations that have been reviewed
  and promoted from the Finding Store for long-term retention.

  Persistent Memory entries preserve the provenance chain: the original
  finding ID, the session that created it, and the promotion timestamp
  provide full auditability.

  This module is pure data and pure functions. It does not touch the
  filesystem, persist events, or dispatch tools.
  """

  alias Tet.Entity

  @enforce_keys [:id, :session_id, :title, :source_finding_id]
  defstruct [
    :id,
    :session_id,
    :title,
    :description,
    :source_finding_id,
    :severity,
    :evidence_refs,
    :promoted_at,
    :created_at,
    metadata: %{}
  ]

  @type severity :: :info | :warning | :critical
  @type t :: %__MODULE__{
          id: binary(),
          session_id: binary(),
          title: binary(),
          description: binary() | nil,
          source_finding_id: binary(),
          severity: severity() | nil,
          evidence_refs: [map()] | nil,
          promoted_at: DateTime.t() | nil,
          created_at: DateTime.t() | nil,
          metadata: map()
        }

  @doc "Builds a validated persistent memory entry from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :persistent_memory),
         {:ok, session_id} <- Entity.fetch_required_binary(attrs, :session_id, :persistent_memory),
         {:ok, title} <- Entity.fetch_required_binary(attrs, :title, :persistent_memory),
         {:ok, description} <-
           Entity.fetch_optional_binary(attrs, :description, :persistent_memory),
         {:ok, source_finding_id} <-
           Entity.fetch_required_binary(attrs, :source_finding_id, :persistent_memory),
         {:ok, severity} <- fetch_severity(attrs),
         {:ok, evidence_refs} <- fetch_optional_list(attrs, :evidence_refs),
         {:ok, promoted_at} <-
           Entity.fetch_optional_datetime(attrs, :promoted_at, :persistent_memory),
         {:ok, created_at} <-
           Entity.fetch_optional_datetime(attrs, :created_at, :persistent_memory),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :persistent_memory) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         title: title,
         description: description,
         source_finding_id: source_finding_id,
         severity: severity,
         evidence_refs: evidence_refs,
         promoted_at: promoted_at,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_persistent_memory}

  @doc "Converts a persistent memory entry to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      id: entry.id,
      session_id: entry.session_id,
      title: entry.title,
      source_finding_id: entry.source_finding_id
    }
    |> maybe_put(:description, entry.description)
    |> maybe_put(:severity, Entity.atom_to_map(entry.severity))
    |> maybe_put(:evidence_refs, entry.evidence_refs)
    |> maybe_put(:promoted_at, Entity.datetime_to_map(entry.promoted_at))
    |> maybe_put(:created_at, Entity.datetime_to_map(entry.created_at))
    |> Map.put(:metadata, entry.metadata)
  end

  @doc "Converts a decoded map back to a validated persistent memory entry."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Private helpers --

  @severities [:info, :warning, :critical]

  defp fetch_severity(attrs) do
    case Entity.fetch_value(attrs, :severity) do
      nil ->
        {:ok, nil}

      severity when severity in @severities ->
        {:ok, severity}

      severity when is_binary(severity) ->
        case Enum.find(@severities, &(Atom.to_string(&1) == severity)) do
          nil -> {:error, {:invalid_persistent_memory_field, :severity}}
          atom -> {:ok, atom}
        end

      _ ->
        {:error, {:invalid_persistent_memory_field, :severity}}
    end
  end

  defp fetch_optional_list(attrs, key) do
    case Entity.fetch_value(attrs, key) do
      nil -> {:ok, nil}
      value when is_list(value) -> {:ok, value}
      _ -> {:error, {:invalid_persistent_memory_field, key}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
