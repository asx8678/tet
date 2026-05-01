defmodule Tet.Steering do
  @moduledoc """
  Steering decision facade owned by `tet_core` — BD-0031.

  BD-0031 introduces a steering decision schema that captures whether the
  agent should continue as-is, focus its scope, receive guidance, or block
  with a hard reason. This facade composes the decision and context modules
  into a single public API surface for the rest of the umbrella.

  ## What this module does

  - Provides default steering decision and context constructors.
  - Exposes validation, serialization, and query helpers.
  - Keeps steering pure and side-effect-free: no filesystem, no shell,
    no GenServer.

  ## What this module does NOT do

  - Run an LLM evaluator (future `Tet.Runtime.SteeringAgent` concern).
  - Override deterministic policy gates (BD-0025).
  - Persist or emit steering events (runtime concern).
  """

  alias Tet.Steering.{Context, Decision}

  @doc "Returns all valid steering decision types."
  @spec decision_types() :: [Decision.type()]
  def decision_types, do: Decision.types()

  @doc "Returns steering decision types that carry a guidance_message."
  @spec guidance_types() :: [Decision.type()]
  def guidance_types, do: Decision.guidance_types()

  @doc "Builds a validated steering decision."
  @spec new_decision(map()) :: {:ok, Decision.t()} | {:error, term()}
  def new_decision(attrs), do: Decision.new(attrs)

  @doc "Builds a steering decision or raises."
  @spec new_decision!(map()) :: Decision.t()
  def new_decision!(attrs), do: Decision.new!(attrs)

  @doc "Builds a validated steering context."
  @spec new_context(map()) :: {:ok, Context.t()} | {:error, term()}
  def new_context(attrs), do: Context.new(attrs)

  @doc "Builds a steering context or raises."
  @spec new_context!(map()) :: Context.t()
  def new_context!(attrs), do: Context.new!(attrs)

  @doc "True when the decision type is `:continue`."
  @spec continue?(Decision.t()) :: boolean()
  defdelegate continue?(decision), to: Decision

  @doc "True when the decision type is `:focus`."
  @spec focus?(Decision.t()) :: boolean()
  defdelegate focus?(decision), to: Decision

  @doc "True when the decision type is `:guide`."
  @spec guide?(Decision.t()) :: boolean()
  defdelegate guide?(decision), to: Decision

  @doc "True when the decision type is `:block`."
  @spec block?(Decision.t()) :: boolean()
  defdelegate block?(decision), to: Decision

  @doc "True when the decision carries a guidance_message."
  @spec has_guidance?(Decision.t()) :: boolean()
  defdelegate has_guidance?(decision), to: Decision

  @doc "Converts a decision to a JSON-friendly map."
  @spec decision_to_map(Decision.t()) :: map()
  defdelegate decision_to_map(decision), to: Decision, as: :to_map

  @doc "Converts a decoded map back to a validated decision."
  @spec decision_from_map(map()) :: {:ok, Decision.t()} | {:error, term()}
  defdelegate decision_from_map(attrs), to: Decision, as: :from_map

  @doc "Converts a context to a JSON-friendly map."
  @spec context_to_map(Context.t()) :: map()
  defdelegate context_to_map(ctx), to: Context, as: :to_map

  @doc "Converts a decoded map back to a validated context."
  @spec context_from_map(map()) :: {:ok, Context.t()} | {:error, term()}
  defdelegate context_from_map(attrs), to: Context, as: :from_map
end
