defmodule Tet.Steering do
  @moduledoc """
  Steering decision facade owned by `tet_core` — BD-0031, BD-0033.

  BD-0031 introduces a steering decision schema that captures whether the
  agent should continue as-is, focus its scope, receive guidance, or block
  with a hard reason. BD-0033 extends this with guidance message persistence
  and lifecycle management.

  This facade composes the decision, context, guidance message, and guidance
  store modules into a single public API surface for the rest of the umbrella.

  ## What this module does

  - Provides default steering decision and context constructors.
  - Exposes validation, serialization, and query helpers.
  - Provides guidance message construction and lifecycle management.
  - Provides guidance store operations (add, expire, query, serialize).
  - Keeps steering pure and side-effect-free: no filesystem, no shell,
    no GenServer.

  ## What this module does NOT do

  - Run an LLM evaluator (future `Tet.Runtime.SteeringAgent` concern).
  - Override deterministic policy gates (BD-0025).
  - Persist or emit steering events (runtime concern).
  """

  alias Tet.Steering.{Context, Decision, GuidanceMessage, GuidanceStore}

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

  # ── GuidanceMessage (BD-0033) ─────────────────────────────────────

  @doc "Builds a validated guidance message."
  @spec new_guidance_message(map()) :: {:ok, GuidanceMessage.t()} | {:error, term()}
  defdelegate new_guidance_message(attrs), to: GuidanceMessage, as: :new

  @doc "Builds a guidance message or raises."
  @spec new_guidance_message!(map()) :: GuidanceMessage.t()
  defdelegate new_guidance_message!(attrs), to: GuidanceMessage, as: :new!

  @doc "Builds a guidance message from a steering decision."
  @spec guidance_from_decision(Decision.t(), keyword()) ::
          {:ok, GuidanceMessage.t()} | {:error, term()}
  defdelegate guidance_from_decision(decision, opts), to: GuidanceMessage, as: :from_decision

  @doc "True when the guidance message is active."
  @spec guidance_active?(GuidanceMessage.t()) :: boolean()
  defdelegate guidance_active?(msg), to: GuidanceMessage, as: :active?

  @doc "Converts a guidance message to a JSON-friendly map."
  @spec guidance_message_to_map(GuidanceMessage.t()) :: map()
  defdelegate guidance_message_to_map(msg), to: GuidanceMessage, as: :to_map

  @doc "Converts a decoded map back to a validated guidance message."
  @spec guidance_message_from_map(map()) :: {:ok, GuidanceMessage.t()} | {:error, term()}
  defdelegate guidance_message_from_map(attrs), to: GuidanceMessage, as: :from_map

  # ── GuidanceStore (BD-0033) ───────────────────────────────────────

  @doc "Creates an empty guidance store."
  @spec new_guidance_store() :: GuidanceStore.store()
  defdelegate new_guidance_store(), to: GuidanceStore, as: :new

  @doc "Adds a guidance message to the store."
  @spec guidance_store_add(GuidanceStore.store(), GuidanceMessage.t()) :: GuidanceStore.store()
  defdelegate guidance_store_add(store, msg), to: GuidanceStore, as: :add

  @doc "Expires all active guidance messages for the given session in the store."
  @spec guidance_store_expire_by_session(GuidanceStore.store(), binary()) :: GuidanceStore.store()
  defdelegate guidance_store_expire_by_session(store, session_id),
    to: GuidanceStore,
    as: :expire_by_session

  @doc "Returns active (non-expired) guidance messages."
  @spec guidance_store_active(GuidanceStore.store()) :: [GuidanceMessage.t()]
  defdelegate guidance_store_active(store), to: GuidanceStore, as: :active

  @doc "Returns active guidance messages for a session."
  @spec guidance_store_active_by_session(GuidanceStore.store(), binary()) :: [GuidanceMessage.t()]
  defdelegate guidance_store_active_by_session(store, session_id),
    to: GuidanceStore,
    as: :active_by_session

  @doc "Converts the store to a JSON-friendly list."
  @spec guidance_store_to_list(GuidanceStore.store()) :: [map()]
  defdelegate guidance_store_to_list(store), to: GuidanceStore, as: :to_list

  @doc "Builds a store from a list of maps."
  @spec guidance_store_from_list([map()]) :: {:ok, GuidanceStore.store()} | {:error, term()}
  defdelegate guidance_store_from_list(maps), to: GuidanceStore, as: :from_list

  @doc "Returns the count of active guidance messages."
  @spec guidance_store_active_count(GuidanceStore.store()) :: non_neg_integer()
  defdelegate guidance_store_active_count(store), to: GuidanceStore, as: :active_count
end
