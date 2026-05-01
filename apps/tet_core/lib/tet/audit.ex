defmodule Tet.Audit do
  @moduledoc """
  Core audit entry struct for the append-only audit stream — BD-0069.

  Each audit entry is an immutable record of an action taken within the system.
  Entries are created, never updated or deleted. The `metadata` field is always
  redacted before export; the `payload_ref` points to the full payload stored
  separately.

  This module is pure data and pure functions. It does not manage storage or
  perform I/O.
  """

  alias Tet.Entity
  alias Tet.Redactor

  @event_types [:tool_call, :message, :approval, :repair, :error, :config_change]
  @actions [:create, :read, :update, :delete, :execute]
  @actors [:user, :agent, :system, :remote]
  @outcomes [:success, :failure, :denied, :pending]

  @enforce_keys [:id, :timestamp, :event_type, :action, :actor]
  defstruct [
    :id,
    :timestamp,
    :session_id,
    :event_type,
    :action,
    :actor,
    :resource,
    :outcome,
    :payload_ref,
    metadata: %{}
  ]

  @type event_type :: :tool_call | :message | :approval | :repair | :error | :config_change
  @type action :: :create | :read | :update | :delete | :execute
  @type actor :: :user | :agent | :system | :remote
  @type outcome :: :success | :failure | :denied | :pending

  @type t :: %__MODULE__{
          id: binary(),
          timestamp: DateTime.t(),
          session_id: binary() | nil,
          event_type: event_type(),
          action: action(),
          actor: actor(),
          resource: binary() | nil,
          outcome: outcome() | nil,
          metadata: map(),
          payload_ref: binary() | nil
        }

  @doc "Returns valid audit event types."
  @spec event_types() :: [event_type()]
  def event_types, do: @event_types

  @doc "Returns valid audit actions."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc "Returns valid audit actors."
  @spec actors() :: [actor()]
  def actors, do: @actors

  @doc "Returns valid audit outcomes."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc """
  Validates and creates an audit entry from atom or string keyed attrs.

  Auto-generates `:id` and `:timestamp` when not provided.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_id(attrs),
         {:ok, timestamp} <- fetch_timestamp(attrs),
         {:ok, session_id} <- Entity.fetch_optional_binary(attrs, :session_id, :audit),
         {:ok, event_type} <- Entity.fetch_atom(attrs, :event_type, @event_types, :audit),
         {:ok, action} <- Entity.fetch_atom(attrs, :action, @actions, :audit),
         {:ok, actor} <- Entity.fetch_atom(attrs, :actor, @actors, :audit),
         {:ok, resource} <- Entity.fetch_optional_binary(attrs, :resource, :audit),
         {:ok, outcome} <- fetch_optional_outcome(attrs),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :audit),
         {:ok, payload_ref} <- Entity.fetch_optional_binary(attrs, :payload_ref, :audit) do
      {:ok,
       %__MODULE__{
         id: id,
         timestamp: timestamp,
         session_id: session_id,
         event_type: event_type,
         action: action,
         actor: actor,
         resource: resource,
         outcome: outcome,
         metadata: metadata,
         payload_ref: payload_ref
       }}
    end
  end

  def new(_), do: {:error, :invalid_audit_entry}

  @doc "Converts an audit entry to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      id: entry.id,
      timestamp: Entity.datetime_to_map(entry.timestamp),
      session_id: entry.session_id,
      event_type: Entity.atom_to_map(entry.event_type),
      action: Entity.atom_to_map(entry.action),
      actor: Entity.atom_to_map(entry.actor),
      resource: entry.resource,
      outcome: Entity.atom_to_map(entry.outcome),
      metadata: entry.metadata,
      payload_ref: entry.payload_ref
    }
  end

  @doc "Converts a decoded map back to a validated audit entry."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Applies redaction to all fields that can contain sensitive data."
  @spec redact(t()) :: t()
  def redact(%__MODULE__{} = entry) do
    %__MODULE__{
      entry
      | metadata: Redactor.redact(entry.metadata),
        resource:
          if(is_binary(entry.resource),
            do: Redactor.redact(entry.resource),
            else: entry.resource
          ),
        payload_ref:
          if(is_binary(entry.payload_ref),
            do: Redactor.redact(entry.payload_ref),
            else: entry.payload_ref
          )
    }
  end

  # -- Private helpers --

  defp fetch_id(attrs) do
    case Entity.fetch_value(attrs, :id) do
      nil -> {:ok, generate_id()}
      "" -> {:ok, generate_id()}
      value when is_binary(value) -> {:ok, value}
      _ -> Entity.field_error(:audit, :id)
    end
  end

  @doc false
  def generate_id do
    "aud_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp fetch_timestamp(attrs) do
    case Entity.fetch_value(attrs, :timestamp) do
      nil ->
        {:ok, DateTime.utc_now()}

      %DateTime{} = dt ->
        {:ok, dt}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> {:ok, dt}
          {:error, _} -> Entity.field_error(:audit, :timestamp)
        end

      _ ->
        Entity.field_error(:audit, :timestamp)
    end
  end

  defp fetch_optional_outcome(attrs) do
    case Entity.fetch_value(attrs, :outcome) do
      nil ->
        {:ok, nil}

      value when is_atom(value) ->
        if value in @outcomes, do: {:ok, value}, else: Entity.value_error(:audit, :outcome)

      value when is_binary(value) ->
        case Enum.find(@outcomes, &(Atom.to_string(&1) == value)) do
          nil -> Entity.value_error(:audit, :outcome)
          atom -> {:ok, atom}
        end

      _ ->
        Entity.field_error(:audit, :outcome)
    end
  end
end
