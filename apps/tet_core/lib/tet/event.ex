defmodule Tet.Event do
  @moduledoc """
  Minimal runtime-event shape shared by runtime, stores, CLI, and future UI adapters.

  Runtime owns event creation and publication. This core struct only defines the
  stable data contract plus JSON-friendly conversion helpers so adapters do not
  reach into runtime internals or invent their own event maps like tiny gremlins.
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

  @profile_swap_types [
    :profile_swap_queued,
    :profile_swap_applied,
    :profile_swap_rejected
  ]

  @provider_route_types [
    :provider_route_decision,
    :provider_route_attempt,
    :provider_route_retry,
    :provider_route_fallback,
    :provider_route_done,
    :provider_route_error
  ]

  @known_types [
                 :assistant_chunk,
                 :message_persisted,
                 :session_started,
                 :session_resumed
               ] ++ @provider_types ++ @provider_route_types ++ @profile_swap_types

  @enforce_keys [:type]
  defstruct [:type, :session_id, :sequence, payload: %{}, metadata: %{}]

  @type type ::
          :assistant_chunk
          | :message_persisted
          | :session_started
          | :session_resumed
          | :profile_swap_queued
          | :profile_swap_applied
          | :profile_swap_rejected
          | :provider_start
          | :provider_text_delta
          | :provider_tool_call_delta
          | :provider_tool_call_done
          | :provider_usage
          | :provider_done
          | :provider_error
          | :provider_route_decision
          | :provider_route_attempt
          | :provider_route_retry
          | :provider_route_fallback
          | :provider_route_done
          | :provider_route_error
  @type t :: %__MODULE__{
          type: type(),
          session_id: binary() | nil,
          sequence: non_neg_integer() | nil,
          payload: map(),
          metadata: map()
        }

  @doc "Returns the core event types currently emitted by the runtime shell."
  def known_types, do: @known_types

  @doc "Returns the normalized provider lifecycle event types."
  def provider_types, do: @provider_types

  @doc "Returns auditable provider router decision event types."
  def provider_route_types, do: @provider_route_types

  @doc "Returns profile swap lifecycle event types."
  def profile_swap_types, do: @profile_swap_types

  @doc "Builds a normalized profile-swap-queued event."
  def profile_swap_queued(payload \\ %{}, opts \\ []) when is_map(payload) and is_list(opts) do
    swap_event(:profile_swap_queued, payload, opts)
  end

  @doc "Builds a normalized profile-swap-applied event."
  def profile_swap_applied(payload \\ %{}, opts \\ []) when is_map(payload) and is_list(opts) do
    swap_event(:profile_swap_applied, payload, opts)
  end

  @doc "Builds a normalized profile-swap-rejected event."
  def profile_swap_rejected(payload \\ %{}, opts \\ []) when is_map(payload) and is_list(opts) do
    swap_event(:profile_swap_rejected, payload, opts)
  end

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

  defp provider_event(type, payload, opts) do
    %__MODULE__{
      type: type,
      session_id: Keyword.get(opts, :session_id),
      sequence: Keyword.get(opts, :sequence),
      payload: payload,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp swap_event(type, payload, opts) do
    %__MODULE__{
      type: type,
      session_id: Keyword.get(opts, :session_id),
      sequence: Keyword.get(opts, :sequence),
      payload: payload,
      metadata: Keyword.get(opts, :metadata, %{})
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
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when value in [nil, true, false], do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key
end
