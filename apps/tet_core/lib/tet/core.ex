defmodule Tet.Core do
  @moduledoc """
  Pure Tet domain boundary.

  This scaffold intentionally exposes only compile-time contracts and tiny
  metadata helpers. Runtime orchestration, process supervision, persistence,
  terminal rendering, and provider calls live in their own applications.
  """

  @capabilities [
    :contracts,
    :events,
    :messages,
    :prompts,
    :prompt_lab,
    :provider_behaviour,
    :store_behaviour
  ]

  @doc "Returns the conceptual capabilities reserved by the core app."
  def capabilities, do: @capabilities

  @doc "Returns static metadata for the core application boundary."
  def boundary do
    %{
      application: :tet_core,
      owns: @capabilities,
      side_effects: false
    }
  end
end
