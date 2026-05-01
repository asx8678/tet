defmodule Tet.Event do
  @moduledoc """
  Minimal runtime-event shape shared by runtime, stores, CLI, and future UI adapters.

  Runtime owns event creation and publication. This core struct only defines the
  stable data contract plus JSON-friendly conversion helpers so adapters do not
  reach into runtime internals or invent their own event maps like tiny gremlins.

  `t/0` remains permissive for transient provider/runtime events that have not
  yet been bound to a session. Store callbacks use `persisted_t/0` for the §04
  durable per-session timeline, where `session_id` and `seq` are non-null.
  """

  @provider_types [
    :provider_start,
    :provider_text_delta,
    :provider_tool_call_delta,
    :provider_tool_call_done,
    :provider_usage,
    :provider_done,
    :provider_error
  ]

  @provider_route_types [
    :provider_route_decision,
    :provider_route_attempt,
    :provider_route_retry,
    :provider_route_fallback,
    :provider_route_done,
    :provider_route_error
  ]

  @v03_types [
    :"workspace.created",
    :"workspace.trusted",
    :"session.created",
    :"session.status_changed",
    :"message.user.saved",
    :"message.assistant.saved",
    :"provider.started",
    :"provider.text_delta",
    :"provider.usage",
    :"provider.done",
    :"provider.error",
    :"tool.requested",
    :"tool.blocked",
    :"tool.started",
    :"tool.finished",
    :"approval.created",
    :"approval.approved",
    :"approval.rejected",
    :"artifact.created",
    :"patch.applied",
    :"patch.failed",
    :"verifier.started",
    :"verifier.finished",
    :"error.recorded"
  ]

  @known_types [
                 :assistant_chunk,
                 :message_persisted,
                 :session_started,
                 :session_resumed
               ] ++ @provider_types ++ @provider_route_types ++ @v03_types

  @enforce_keys [:type]
  defstruct [:id, :type, :session_id, :sequence, :seq, :created_at, payload: %{}, metadata: %{}]

  @type type :: atom()
  @type t :: %__MODULE__{
          id: binary() | nil,
          type: type(),
          session_id: binary() | nil,
          sequence: non_neg_integer() | nil,
          seq: non_neg_integer() | nil,
          payload: map(),
          metadata: map(),
          created_at: DateTime.t() | binary() | nil
        }

  @type persisted_t :: %__MODULE__{
          id: binary() | nil,
          type: type(),
          session_id: binary(),
          sequence: non_neg_integer() | nil,
          seq: non_neg_integer(),
          payload: map(),
          metadata: map(),
          created_at: DateTime.t() | binary() | nil
        }

  @doc "Returns the core event types currently emitted by the runtime shell."
  def known_types, do: @known_types

  @doc "Returns the normalized provider lifecycle event types."
  def provider_types, do: @provider_types

  @doc "Returns auditable provider router decision event types."
  def provider_route_types, do: @provider_route_types

  @doc "Builds a normalized provider-start event."
  def provider_start(payload \\ %{}, opts \\ []) when is_map(payload) and is_list(opts) do
    provider_event(:provider_start, payload, opts)
  end

  @doc "Builds a normalized provider text-delta event."
  def provider_text_delta(text, payload \\ %{}, opts \\ [])
      when is_binary(text) and is_map(payload) and is_list(opts) do
    provider_event(:provider_text_delta, Map.put(payload, :text, text), opts)
  end

  @doc "Builds a normalized provider tool-call delta event."
  def provider_tool_call_delta(index, arguments_delta, payload \\ %{}, opts \\ [])
      when is_integer(index) and index >= 0 and is_binary(arguments_delta) and is_map(payload) and
             is_list(opts) do
    payload =
      payload
      |> Map.put(:index, index)
      |> Map.put(:arguments_delta, arguments_delta)

    provider_event(:provider_tool_call_delta, payload, opts)
  end

  @doc "Builds a normalized provider completed tool-call event."
  def provider_tool_call_done(index, id, name, arguments, payload \\ %{}, opts \\ [])
      when is_integer(index) and index >= 0 and is_binary(id) and is_binary(name) and
             is_map(arguments) and is_map(payload) and is_list(opts) do
    payload =
      payload
      |> Map.put(:index, index)
      |> Map.put(:id, id)
      |> Map.put(:name, name)
      |> Map.put(:arguments, arguments)

    provider_event(:provider_tool_call_done, payload, opts)
  end

  @doc "Builds a normalized provider usage event."
  def provider_usage(usage, payload \\ %{}, opts \\ [])
      when is_map(usage) and is_map(payload) and is_list(opts) do
    provider_event(:provider_usage, Map.merge(payload, usage), opts)
  end

  @doc "Builds a normalized provider-done event."
  def provider_done(stop_reason, payload \\ %{}, opts \\ [])
      when is_atom(stop_reason) and is_map(payload) and is_list(opts) do
    provider_event(:provider_done, Map.put(payload, :stop_reason, stop_reason), opts)
  end

  @doc "Builds a normalized provider-error event."
  def provider_error(kind, detail, payload \\ %{}, opts \\ [])
      when is_atom(kind) and is_map(payload) and is_list(opts) do
    payload =
      payload
      |> Map.put(:kind, kind)
      |> Map.put(:detail, detail)

    provider_event(:provider_error, payload, opts)
  end

  @doc "Builds a validated event from atom or string keyed attrs."
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_optional_binary(attrs, :id),
         {:ok, type} <- fetch_type(attrs),
         {:ok, session_id} <- fetch_optional_binary(attrs, :session_id),
         {:ok, sequence} <- fetch_optional_sequence(attrs, :sequence),
         {:ok, seq} <- fetch_optional_sequence(attrs, :seq),
         {:ok, payload} <- fetch_map(attrs, :payload),
         {:ok, metadata} <- fetch_map(attrs, :metadata),
         {:ok, created_at} <- fetch_optional_timestamp(attrs, :created_at) do
      normalized_sequence = sequence || seq

      {:ok,
       %__MODULE__{
         id: id,
         type: type,
         session_id: session_id,
         sequence: normalized_sequence,
         seq: seq || normalized_sequence,
         payload: payload,
         metadata: metadata,
         created_at: created_at
       }}
    end
  end

  @doc "Converts an event to a JSON-friendly map with stable string event types."
  def to_map(%__MODULE__{} = event) do
    seq = event.seq || event.sequence

    %{
      id: event.id,
      type: Atom.to_string(event.type),
      session_id: event.session_id,
      sequence: event.sequence || seq,
      seq: seq,
      payload: json_safe(event.payload),
      metadata: json_safe(event.metadata),
      created_at: timestamp_value(event.created_at)
    }
  end

  @doc "Converts a decoded map back to a validated event struct."
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  defp provider_event(type, payload, opts) do
    sequence = Keyword.get(opts, :sequence)
    seq = Keyword.get(opts, :seq, sequence)

    %__MODULE__{
      id: Keyword.get(opts, :id),
      type: type,
      session_id: Keyword.get(opts, :session_id),
      sequence: sequence || seq,
      seq: seq,
      payload: payload,
      metadata: Keyword.get(opts, :metadata, %{}),
      created_at: Keyword.get(opts, :created_at)
    }
  end

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

  defp fetch_optional_sequence(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_event_field, key}}
    end
  end

  defp fetch_optional_timestamp(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      %DateTime{} = value -> {:ok, value}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_event_field, key}}
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

  defp timestamp_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp_value(value), do: value

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {json_key(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when value in [nil, true, false], do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key
end
