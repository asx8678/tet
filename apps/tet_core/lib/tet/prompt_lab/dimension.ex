defmodule Tet.PromptLab.Dimension do
  @moduledoc """
  Prompt Lab quality dimension contract.

  Dimensions define stable scoring buckets for prompt refinement. Scores are a
  simple 1..10 scale where higher is better, including ambiguity control (less
  ambiguity means a higher score). Tiny scale, fewer rubric gremlins.
  """

  alias Tet.PromptLab.Schema

  @version "tet.prompt_lab.dimension.v1"
  @score_min 1
  @score_max 10

  @enforce_keys [:id, :label, :description, :rubric]
  defstruct [
    :id,
    :label,
    :description,
    :rubric,
    version: @version,
    score_min: @score_min,
    score_max: @score_max,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: binary(),
          version: binary(),
          label: binary(),
          description: binary(),
          rubric: binary(),
          score_min: pos_integer(),
          score_max: pos_integer(),
          metadata: map()
        }

  @doc "Returns the dimension contract version."
  @spec version() :: binary()
  def version, do: @version

  @doc "Builds a validated quality dimension from atom or string keyed attrs."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Schema.attrs_map(attrs)

    with {:ok, id} <- required_id(attrs),
         {:ok, label} <- Schema.required_binary(attrs, :label, {:invalid_dimension, :label}),
         {:ok, description} <-
           Schema.required_binary(attrs, :description, {:invalid_dimension, :description}),
         {:ok, rubric} <- Schema.required_binary(attrs, :rubric, {:invalid_dimension, :rubric}),
         {:ok, score_min} <- score_bound(attrs, :score_min, @score_min),
         {:ok, score_max} <- score_bound(attrs, :score_max, @score_max),
         :ok <- validate_score_range(score_min, score_max),
         {:ok, metadata} <- Schema.metadata(attrs, :metadata, :invalid_dimension_metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         label: label,
         description: description,
         rubric: rubric,
         score_min: score_min,
         score_max: score_max,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_dimension}

  @doc "Converts decoded JSON-ish data back to a dimension."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Returns a JSON-friendly dimension map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = dimension) do
    %{
      id: dimension.id,
      version: dimension.version,
      label: dimension.label,
      description: dimension.description,
      rubric: dimension.rubric,
      score_min: dimension.score_min,
      score_max: dimension.score_max,
      metadata: dimension.metadata
    }
  end

  @doc "Returns true when a score is inside the dimension scale."
  @spec valid_score?(t(), term()) :: boolean()
  def valid_score?(%__MODULE__{score_min: min, score_max: max}, score) do
    is_integer(score) and score >= min and score <= max
  end

  defp required_id(attrs) do
    with {:ok, id} <- Schema.required_binary(attrs, :id, {:invalid_dimension, :id}) do
      Schema.validate_id(id, {:invalid_dimension, :id})
    end
  end

  defp score_bound(attrs, key, default) do
    case Schema.fetch_value(attrs, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, {:invalid_dimension, key}}
    end
  end

  defp validate_score_range(score_min, score_max) when score_min < score_max, do: :ok

  defp validate_score_range(_score_min, _score_max),
    do: {:error, {:invalid_dimension, :score_range}}
end
