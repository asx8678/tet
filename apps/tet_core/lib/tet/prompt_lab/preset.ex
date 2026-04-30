defmodule Tet.PromptLab.Preset do
  @moduledoc """
  Prompt Lab preset contract.

  A preset is a prompt-improvement rubric. It is not a runtime profile, not a
  permission grant, and absolutely not a sneaky place to hide tool execution.
  """

  alias Tet.PromptLab.Schema

  @version "tet.prompt_lab.preset.v1"

  @enforce_keys [:id, :name, :description, :dimensions, :instructions]
  defstruct [
    :id,
    :name,
    :description,
    :dimensions,
    :instructions,
    version: @version,
    tags: [],
    output_style: "structured_prompt",
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: binary(),
          version: binary(),
          name: binary(),
          description: binary(),
          dimensions: [binary()],
          instructions: [binary()],
          tags: [binary()],
          output_style: binary(),
          metadata: map()
        }

  @doc "Returns the preset contract version."
  @spec version() :: binary()
  def version, do: @version

  @doc "Builds a validated Prompt Lab preset from atom or string keyed attrs."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Schema.attrs_map(attrs)

    with {:ok, id} <- required_id(attrs),
         {:ok, name} <- Schema.required_binary(attrs, :name, {:invalid_preset, :name}),
         {:ok, description} <-
           Schema.required_binary(attrs, :description, {:invalid_preset, :description}),
         {:ok, dimensions} <-
           Schema.required_string_list(attrs, :dimensions, {:invalid_preset, :dimensions}),
         {:ok, instructions} <-
           Schema.required_string_list(attrs, :instructions, {:invalid_preset, :instructions}),
         {:ok, tags} <- Schema.optional_string_list(attrs, :tags, [], {:invalid_preset, :tags}),
         {:ok, output_style} <-
           Schema.optional_binary(
             attrs,
             :output_style,
             "structured_prompt",
             {:invalid_preset, :output_style}
           ),
         {:ok, metadata} <- Schema.metadata(attrs, :metadata, :invalid_preset_metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: description,
         dimensions: dimensions,
         instructions: instructions,
         tags: tags,
         output_style: output_style,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_preset}

  @doc "Converts decoded JSON-ish data back to a preset."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Returns a JSON-friendly preset map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = preset) do
    %{
      id: preset.id,
      version: preset.version,
      name: preset.name,
      description: preset.description,
      dimensions: preset.dimensions,
      instructions: preset.instructions,
      tags: preset.tags,
      output_style: preset.output_style,
      metadata: preset.metadata
    }
  end

  defp required_id(attrs) do
    with {:ok, id} <- Schema.required_binary(attrs, :id, {:invalid_preset, :id}) do
      Schema.validate_id(id, {:invalid_preset, :id})
    end
  end
end
