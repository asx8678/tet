defmodule Tet.PromptLab.Request do
  @moduledoc """
  Prompt Lab refinement request contract.

  Requests are explicit data supplied by a caller. Prompt Lab does not go read a
  workspace, scrape a session, or ask tools for context behind your back.
  """

  alias Tet.PromptLab.Schema

  @version "tet.prompt_lab.request.v1"

  @enforce_keys [:prompt, :preset_id]
  defstruct [:prompt, :preset_id, version: @version, dimensions: [], metadata: %{}]

  @type t :: %__MODULE__{
          version: binary(),
          prompt: binary(),
          preset_id: binary(),
          dimensions: [binary()],
          metadata: map()
        }

  @doc "Returns the request contract version."
  @spec version() :: binary()
  def version, do: @version

  @doc "Builds a validated refinement request from atom or string keyed attrs."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Schema.attrs_map(attrs)

    with {:ok, prompt} <- Schema.required_binary(attrs, :prompt, :empty_prompt),
         {:ok, preset_id} <-
           Schema.required_binary(attrs, :preset_id, {:invalid_request, :preset_id}),
         {:ok, preset_id} <- Schema.validate_id(preset_id, {:invalid_request, :preset_id}),
         {:ok, dimensions} <-
           Schema.optional_string_list(attrs, :dimensions, [], {:invalid_request, :dimensions}),
         {:ok, metadata} <- Schema.metadata(attrs, :metadata, :invalid_request_metadata) do
      {:ok,
       %__MODULE__{
         prompt: prompt,
         preset_id: preset_id,
         dimensions: dimensions,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_request}

  @doc "Converts decoded JSON-ish data back to a request."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Returns a JSON-friendly request map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    %{
      version: request.version,
      prompt: request.prompt,
      preset_id: request.preset_id,
      dimensions: request.dimensions,
      metadata: request.metadata
    }
  end
end
