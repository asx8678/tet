defmodule Tet.Steering.GuidanceMessage do
  @moduledoc """
  A persisted guidance message with event references — BD-0033.

  Captures a focus or guide decision from the steering evaluator, correlated
  with the task/tool event that triggered it. Messages track their lifecycle
  via an `expired` flag so the runtime loop can expire active guidance when
  new task/tool events arrive.

  ## Fields

    - `id` — unique identifier (binary)
    - `session_id` — session this guidance belongs to
    - `event_seq` — event sequence number that produced this guidance
    - `decision_type` — `:focus` or `:guide`
    - `message` — the actionable guidance text
    - `trigger_event_type` — type of the triggering event (e.g. `:tool.started`)
    - `trigger_event_seq` — sequence of the triggering event
    - `expired` — boolean, false when active, true when superseded
    - `created_at` — timestamp of creation

  ## Relationship to other modules

    - `Tet.Steering.Decision` (BD-0031): carries the `guidance_message` and
      `type` (:focus or :guide) that this struct captures.
    - `Tet.Steering.GuidanceStore`: collection management for these messages.
    - `Tet.Runtime.GuidanceLoop` (BD-0033): runtime process that creates,
      persists, and expires these messages.
  """

  @enforce_keys [:id, :session_id, :event_seq, :decision_type, :message]
  defstruct [
    :id,
    :session_id,
    :event_seq,
    :decision_type,
    :message,
    :trigger_event_type,
    :trigger_event_seq,
    expired: false,
    created_at: nil
  ]

  @type decision_type :: :focus | :guide

  @type t :: %__MODULE__{
          id: binary(),
          session_id: binary(),
          event_seq: non_neg_integer(),
          decision_type: decision_type(),
          message: binary(),
          trigger_event_type: atom() | nil,
          trigger_event_seq: non_neg_integer() | nil,
          expired: boolean(),
          created_at: DateTime.t() | nil
        }

  @doc """
  Builds a validated guidance message from attributes.

  Required: `:decision_type` (`:focus` or `:guide`), `:message` (non-empty
  binary). The `:id`, `:session_id`, and `:event_seq` are generated
  automatically if not provided, using `Tet.Runtime.Ids` for runtime callers
  or explicit values for testing.

  ## Options

    - `:id` — optional explicit id (auto-generated via UUID if omitted)
    - `:session_id` — optional session id
    - `:event_seq` — optional event sequence (default 0)
    - `:trigger_event_type` — optional atom for the triggering event type
    - `:trigger_event_seq` — optional sequence of the triggering event
    - `:expired` — boolean, defaults to false
    - `:created_at` — optional DateTime (defaults to now in UTC)
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_id(attrs),
         {:ok, session_id} <- fetch_optional_binary(attrs, :session_id, ""),
         {:ok, event_seq} <- fetch_optional_integer(attrs, :event_seq, 0),
         {:ok, decision_type} <- fetch_decision_type(attrs),
         {:ok, message} <- fetch_message(attrs),
         {:ok, trigger_event_type} <- fetch_optional_atom(attrs, :trigger_event_type),
         {:ok, trigger_event_seq} <- fetch_optional_integer(attrs, :trigger_event_seq),
         {:ok, expired} <- fetch_boolean(attrs, :expired, false),
         {:ok, created_at} <- fetch_optional_datetime(attrs, :created_at) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         event_seq: event_seq,
         decision_type: decision_type,
         message: message,
         trigger_event_type: trigger_event_type,
         trigger_event_seq: trigger_event_seq,
         expired: expired,
         created_at: created_at || DateTime.utc_now()
       }}
    end
  end

  @doc "Builds a guidance message or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, msg} -> msg
      {:error, reason} -> raise ArgumentError, "invalid guidance message: #{inspect(reason)}"
    end
  end

  @doc """
  Builds a guidance message from a steering decision and event context.

  Convenience constructor that extracts the decision type and guidance
  message from a `Tet.Steering.Decision` and pairs it with triggering event
  metadata.

  ## Options

    - `:session_id` — session id (required)
    - `:event_seq` — event sequence (required)
    - `:trigger_event_type` — optional trigger event type
    - `:trigger_event_seq` — optional trigger event sequence
  """
  @spec from_decision(Tet.Steering.Decision.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_decision(%Tet.Steering.Decision{} = decision, opts \\ []) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    event_seq = Keyword.fetch!(opts, :event_seq)

    new(%{
      session_id: session_id,
      event_seq: event_seq,
      decision_type: decision.type,
      message: decision.guidance_message || "",
      trigger_event_type: Keyword.get(opts, :trigger_event_type),
      trigger_event_seq: Keyword.get(opts, :trigger_event_seq)
    })
  end

  @doc """
  Marks a guidance message as expired.
  """
  @spec expire(t()) :: t()
  def expire(%__MODULE__{} = msg), do: %__MODULE__{msg | expired: true}

  @doc "True when the message is active (not expired)."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{expired: false}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "True when the message is a focus decision."
  @spec focus?(t()) :: boolean()
  def focus?(%__MODULE__{decision_type: :focus}), do: true
  def focus?(%__MODULE__{}), do: false

  @doc "True when the message is a guide decision."
  @spec guide?(t()) :: boolean()
  def guide?(%__MODULE__{decision_type: :guide}), do: true
  def guide?(%__MODULE__{}), do: false

  @doc "Converts to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = msg) do
    %{
      id: msg.id,
      session_id: msg.session_id,
      event_seq: msg.event_seq,
      decision_type: Atom.to_string(msg.decision_type),
      message: msg.message,
      trigger_event_type: if(msg.trigger_event_type, do: Atom.to_string(msg.trigger_event_type)),
      trigger_event_seq: msg.trigger_event_seq,
      expired: msg.expired,
      created_at: timestamp_value(msg.created_at)
    }
  end

  @doc "Converts a decoded map back to a validated message."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # ── Validators ──────────────────────────────────────────────────────

  defp fetch_id(attrs) do
    case Map.get(attrs, :id, Map.get(attrs, "id")) do
      nil ->
        {:ok, generate_id()}

      id when is_binary(id) and byte_size(id) > 0 ->
        {:ok, id}

      id ->
        {:error, {:invalid_guidance_field, :id, id}}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp fetch_decision_type(attrs) do
    case Map.get(attrs, :decision_type, Map.get(attrs, "decision_type")) do
      type when type in [:focus, :guide] -> {:ok, type}
      "focus" -> {:ok, :focus}
      "guide" -> {:ok, :guide}
      other -> {:error, {:invalid_decision_type, other}}
    end
  end

  defp fetch_message(attrs) do
    case Map.get(attrs, :message, Map.get(attrs, "message")) do
      msg when is_binary(msg) and byte_size(msg) > 0 -> {:ok, msg}
      _ -> {:error, :guidance_message_required}
    end
  end

  defp fetch_optional_binary(attrs, key, default) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default)) do
      nil -> {:ok, default}
      "" -> {:ok, default}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_guidance_field, key}}
    end
  end

  defp fetch_optional_integer(attrs, key, default \\ nil) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil -> {:ok, default}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_guidance_field, key}}
    end
  end

  defp fetch_optional_atom(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil -> {:ok, nil}
      value when is_atom(value) -> {:ok, value}
      value when is_binary(value) -> {:ok, String.to_existing_atom(value)}
      _ -> {:error, {:invalid_guidance_field, key}}
    end
  end

  defp fetch_boolean(attrs, key, default) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default)) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, {:invalid_guidance_field, key}}
    end
  end

  defp fetch_optional_datetime(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      nil -> {:ok, nil}
      %DateTime{} = dt -> {:ok, dt}
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> {:ok, dt}
          _ -> {:ok, nil}
        end
      _ -> {:ok, nil}
    end
  end

  defp timestamp_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp_value(nil), do: nil
  defp timestamp_value(value), do: value
end
