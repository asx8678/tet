defmodule Tet.Steering.Decision do
  @moduledoc """
  Steering decision data — BD-0031.

  A steering decision captures the output of an LLM-backed or deterministic
  steering evaluator: whether to continue as-is, focus the scope, inject a
  guidance message, or block with a hard reason.

  Decisions are pure data. They do not dispatch tools, emit events, or
  touch the filesystem. The caller (e.g. `Tet.Runtime.SteeringAgent`) is
  responsible for interpreting and acting on the decision.

  ## Decision types

    - `:continue` — proceed as-is, no intervention needed.
    - `:focus` — narrow scope or task; carries a `guidance_message`.
    - `:guide` — inject a guidance message without blocking.
    - `:block` — hard stop with a `reason`.

  ## Relationship to other modules

    - `Tet.Steering.Context` (BD-0031): relevance context consumed by the
      evaluator to produce a decision.
    - `Tet.PlanMode.Gate` (BD-0025): deterministic gate decisions run
      *before* steering; steering may guide or focus but never override a
      gate block.
    - `Tet.Event` (BD-0022): decisions can be emitted as steering events
      for auditability.
  """

  @types [:continue, :focus, :guide, :block]
  @guidance_types [:focus, :guide]

  @enforce_keys [:type]
  defstruct [
    :type,
    :reason,
    :guidance_message,
    confidence: 1.0,
    context: %{}
  ]

  @type type :: :continue | :focus | :guide | :block
  @type t :: %__MODULE__{
          type: type(),
          reason: binary() | nil,
          confidence: float(),
          context: map(),
          guidance_message: binary() | nil
        }

  @doc "Returns all valid steering decision types."
  @spec types() :: [type()]
  def types, do: @types

  @doc "Returns steering decision types that carry a guidance_message."
  @spec guidance_types() :: [type()]
  def guidance_types, do: @guidance_types

  @doc """
  Builds a validated steering decision from attributes.

  Required: `:type`.
  Optional: `:reason` (binary), `:confidence` (float, default 1.0),
  `:context` (map, default %{}), `:guidance_message` (binary, required for
  `:focus` and `:guide`).
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, type} <- fetch_type(attrs),
         {:ok, reason} <- fetch_optional_binary(attrs, :reason),
         {:ok, confidence} <- fetch_confidence(attrs),
         {:ok, context} <- fetch_map(attrs, :context, %{}),
         {:ok, guidance_message} <- fetch_optional_binary(attrs, :guidance_message),
         :ok <- validate_guidance_required(type, guidance_message) do
      {:ok,
       %__MODULE__{
         type: type,
         reason: reason,
         confidence: confidence,
         context: context,
         guidance_message: guidance_message
       }}
    end
  end

  @doc "Builds a steering decision or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, decision} -> decision
      {:error, reason} -> raise ArgumentError, "invalid steering decision: #{inspect(reason)}"
    end
  end

  @doc """
  Converts a decision to a JSON-friendly map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = decision) do
    %{
      type: Atom.to_string(decision.type),
      reason: decision.reason,
      confidence: decision.confidence,
      context: json_safe(decision.context),
      guidance_message: decision.guidance_message
    }
  end

  @doc """
  Converts a decoded map back to a validated decision.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "True when the decision type is `:continue`."
  @spec continue?(t()) :: boolean()
  def continue?(%__MODULE__{type: :continue}), do: true
  def continue?(%__MODULE__{}), do: false

  @doc "True when the decision type is `:focus`."
  @spec focus?(t()) :: boolean()
  def focus?(%__MODULE__{type: :focus}), do: true
  def focus?(%__MODULE__{}), do: false

  @doc "True when the decision type is `:guide`."
  @spec guide?(t()) :: boolean()
  def guide?(%__MODULE__{type: :guide}), do: true
  def guide?(%__MODULE__{}), do: false

  @doc "True when the decision type is `:block`."
  @spec block?(t()) :: boolean()
  def block?(%__MODULE__{type: :block}), do: true
  def block?(%__MODULE__{}), do: false

  @doc "True when the decision carries a guidance_message (focus or guide)."
  @spec has_guidance?(t()) :: boolean()
  def has_guidance?(%__MODULE__{type: type}) when type in @guidance_types, do: true
  def has_guidance?(%__MODULE__{}), do: false

  # ── Validators ──────────────────────────────────────────────────────

  defp fetch_type(attrs) do
    case fetch_value(attrs, :type) do
      type when type in @types ->
        {:ok, type}

      type when is_binary(type) ->
        case Enum.find(@types, &(Atom.to_string(&1) == type)) do
          nil -> {:error, {:invalid_steering_type, type}}
          atom -> {:ok, atom}
        end

      type ->
        {:error, {:invalid_steering_type, type}}
    end
  end

  defp fetch_confidence(attrs) do
    case fetch_value(attrs, :confidence, 1.0) do
      confidence when is_float(confidence) and confidence >= 0.0 and confidence <= 1.0 ->
        {:ok, confidence}

      confidence when is_integer(confidence) ->
        # Allow integer shorthand (0 or 1) since JSON may lose float precision
        float = confidence / 1.0

        if float >= 0.0 and float <= 1.0 do
          {:ok, float}
        else
          {:error, {:invalid_confidence, confidence}}
        end

      confidence ->
        {:error, {:invalid_confidence, confidence}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_decision_field, key}}
    end
  end

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_decision_field, key}}
    end
  end

  defp validate_guidance_required(type, guidance_message) when type in @guidance_types do
    if is_binary(guidance_message) and byte_size(guidance_message) > 0 do
      :ok
    else
      {:error, {:guidance_message_required, type}}
    end
  end

  defp validate_guidance_required(_type, _guidance_message), do: :ok

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
