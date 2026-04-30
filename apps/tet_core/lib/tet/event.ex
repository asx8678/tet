defmodule Tet.Event do
  @moduledoc """
  Minimal runtime-event shape shared by runtime, stores, CLI, and future UI adapters.

  Runtime owns event creation and publication. This core struct only defines the
  stable data contract plus JSON-friendly conversion helpers so adapters do not
  reach into runtime internals or invent their own event maps like tiny gremlins.
  """

  @known_types [:assistant_chunk, :message_persisted, :session_started, :session_resumed]

  @enforce_keys [:type]
  defstruct [:type, :session_id, :sequence, payload: %{}, metadata: %{}]

  @type type :: :assistant_chunk | :message_persisted | :session_started | :session_resumed
  @type t :: %__MODULE__{
          type: type(),
          session_id: binary() | nil,
          sequence: non_neg_integer() | nil,
          payload: map(),
          metadata: map()
        }

  @doc "Returns the core event types currently emitted by the runtime shell."
  def known_types, do: @known_types

  @doc "Builds a validated event from atom or string keyed attrs."
  def new(attrs) when is_map(attrs) do
    with {:ok, type} <- fetch_type(attrs),
         {:ok, session_id} <- fetch_optional_binary(attrs, :session_id),
         {:ok, sequence} <- fetch_optional_sequence(attrs),
         {:ok, payload} <- fetch_map(attrs, :payload),
         {:ok, metadata} <- fetch_map(attrs, :metadata) do
      {:ok,
       %__MODULE__{
         type: type,
         session_id: session_id,
         sequence: sequence,
         payload: payload,
         metadata: metadata
       }}
    end
  end

  @doc "Converts an event to a JSON-friendly map with stable string event types."
  def to_map(%__MODULE__{} = event) do
    %{
      type: Atom.to_string(event.type),
      session_id: event.session_id,
      sequence: event.sequence,
      payload: json_safe(event.payload),
      metadata: json_safe(event.metadata)
    }
  end

  @doc "Converts a decoded map back to a validated event struct."
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  defp fetch_type(attrs) do
    case fetch_value(attrs, :type) do
      type when type in @known_types ->
        {:ok, type}

      type when is_binary(type) ->
        case Enum.find(@known_types, &(Atom.to_string(&1) == type)) do
          nil -> {:error, {:invalid_event_type, type}}
          type_atom -> {:ok, type_atom}
        end

      type ->
        {:error, {:invalid_event_type, type}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_event_field, key}}
    end
  end

  defp fetch_optional_sequence(attrs) do
    case fetch_value(attrs, :sequence) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_event_field, :sequence}}
    end
  end

  defp fetch_map(attrs, key) do
    case fetch_value(attrs, key, %{}) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_event_field, key}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {json_key(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when value in [nil, true, false], do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key
end
