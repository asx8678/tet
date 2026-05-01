defmodule Tet.Command.Suggestion do
  @moduledoc """
  Structured suggestion for command correction — BD-0048.

  Represents the result of assessing a command for safety, including
  the original command, an optional safer alternative, the risk level
  assessment, a human-readable reason, whether the command requires
  gate approval before execution, and the type of correction applied.

  This module is pure data and pure functions — no side effects.
  """

  @enforce_keys [:original_command, :risk_level, :reason, :correction_type]
  defstruct [
    :original_command,
    :suggested_command,
    :risk_level,
    :reason,
    :requires_gate,
    :correction_type
  ]

  @type risk_level :: :none | :low | :medium | :high | :critical
  @type correction_type :: :safe | :modified | :blocked

  @type t :: %__MODULE__{
          original_command: String.t(),
          suggested_command: String.t() | nil,
          risk_level: risk_level(),
          reason: String.t(),
          requires_gate: boolean(),
          correction_type: correction_type()
        }

  @risk_levels [:none, :low, :medium, :high, :critical]
  @correction_types [:safe, :modified, :blocked]

  @doc """
  Builds a validated suggestion from attributes.

  Required fields: `:original_command`, `:risk_level`, `:reason`,
  `:correction_type`.

  Optional field: `:suggested_command` (defaults to nil).
  `:requires_gate` is derived automatically from `:risk_level`.

  Returns `{:ok, suggestion}` or `{:error, reason}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, original_command} <- fetch_string(attrs, :original_command),
         {:ok, suggested_command} <- fetch_optional_string(attrs, :suggested_command),
         {:ok, risk_level} <- fetch_risk_level(attrs),
         {:ok, reason} <- fetch_string(attrs, :reason),
         {:ok, correction_type} <- fetch_correction_type(attrs),
         :ok <- validate_requires_gate(attrs, risk_level) do
      requires_gate = Tet.Command.Risk.requires_gate?(risk_level)

      {:ok,
       %__MODULE__{
         original_command: original_command,
         suggested_command: suggested_command,
         risk_level: risk_level,
         reason: reason,
         requires_gate: requires_gate,
         correction_type: correction_type
       }}
    end
  end

  @doc """
  Builds a suggestion or raises.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, suggestion} -> suggestion
      {:error, reason} -> raise ArgumentError, "invalid suggestion: #{inspect(reason)}"
    end
  end

  @doc """
  Converts a suggestion to a JSON-friendly map.

  Atoms are serialized as strings, boolean as-is, nils preserved.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = suggestion) do
    %{
      original_command: suggestion.original_command,
      suggested_command: suggestion.suggested_command,
      risk_level: Atom.to_string(suggestion.risk_level),
      reason: suggestion.reason,
      requires_gate: suggestion.requires_gate,
      correction_type: Atom.to_string(suggestion.correction_type)
    }
  end

  @doc """
  Restores a suggestion from a map (e.g., deserialized JSON).

  Accepts both string and atom keys. String risk/correction values
  are converted back to atoms.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    normalized =
      map
      |> Map.put(
        :original_command,
        Map.get(map, :original_command, Map.get(map, "original_command"))
      )
      |> Map.put(
        :suggested_command,
        Map.get(map, :suggested_command, Map.get(map, "suggested_command"))
      )
      |> Map.put(:risk_level, Map.get(map, :risk_level, Map.get(map, "risk_level")))
      |> Map.put(:reason, Map.get(map, :reason, Map.get(map, "reason")))
      |> Map.put(:requires_gate, Map.get(map, :requires_gate, Map.get(map, "requires_gate")))
      |> Map.put(
        :correction_type,
        Map.get(map, :correction_type, Map.get(map, "correction_type"))
      )

    new(normalized)
  end

  # -- Validators --

  defp fetch_string(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    if is_binary(value) and byte_size(value) > 0 do
      {:ok, value}
    else
      {:error, {:invalid_suggestion_field, key, "must be a non-empty string"}}
    end
  end

  defp fetch_optional_string(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

    cond do
      is_nil(value) -> {:ok, nil}
      is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      is_binary(value) and byte_size(value) == 0 -> {:ok, nil}
      true -> {:error, {:invalid_suggestion_field, key, "must be a string or nil"}}
    end
  end

  defp fetch_risk_level(attrs) do
    value = Map.get(attrs, :risk_level, Map.get(attrs, "risk_level"))
    value = if is_binary(value), do: String.to_existing_atom(value), else: value

    if value in @risk_levels do
      {:ok, value}
    else
      {:error,
       {:invalid_suggestion_field, :risk_level, "must be one of #{inspect(@risk_levels)}"}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_suggestion_field, :risk_level, "unknown atom"}}
  end

  defp validate_requires_gate(attrs, risk_level) do
    value = Map.get(attrs, :requires_gate, Map.get(attrs, "requires_gate"))

    cond do
      is_nil(value) ->
        :ok

      is_boolean(value) and risk_level in [:high, :critical] and value == false ->
        {:error,
         {:invalid_suggestion_field, :requires_gate, "must be true for #{risk_level} risk level"}}

      is_boolean(value) ->
        :ok

      true ->
        {:error, {:invalid_suggestion_field, :requires_gate, "must be a boolean"}}
    end
  end

  defp fetch_correction_type(attrs) do
    value = Map.get(attrs, :correction_type, Map.get(attrs, "correction_type"))
    value = if is_binary(value), do: String.to_existing_atom(value), else: value

    if value in @correction_types do
      {:ok, value}
    else
      {:error,
       {:invalid_suggestion_field, :correction_type,
        "must be one of #{inspect(@correction_types)}"}}
    end
  rescue
    ArgumentError -> {:error, {:invalid_suggestion_field, :correction_type, "unknown atom"}}
  end
end
