defmodule Tet.PromptLab.Refinement do
  @moduledoc """
  Prompt Lab refiner output contract.

  A refinement is structured prompt-improvement output. It may contain raw
  original/refined prompt text because this is the dedicated Prompt Lab result,
  but its debug shape omits prompt content and redacts metadata. It never
  contains executable tool calls, shell commands, patches, or provider requests.
  """

  alias Tet.Prompt.Canonical
  alias Tet.PromptLab.{Preset, Schema}

  @version "tet.prompt_lab.refinement.v1"
  @statuses ~w(improved needs_clarification unchanged)
  @allowed_fields ~w(
    changes
    id
    metadata
    original_prompt
    original_sha256
    preset_id
    preset_version
    questions
    refined_prompt
    refined_sha256
    safety
    scores_after
    scores_before
    status
    summary
    version
    warnings
  )
  @change_fields ~w(dimension impact kind rationale)
  @default_safety %{
    "mutates_outside_prompt_history" => false,
    "provider_called" => false,
    "tools_executed" => false
  }

  @enforce_keys [
    :id,
    :preset_id,
    :preset_version,
    :status,
    :original_prompt,
    :refined_prompt,
    :summary,
    :scores_before,
    :scores_after,
    :original_sha256,
    :refined_sha256
  ]
  defstruct [
    :id,
    :preset_id,
    :preset_version,
    :status,
    :original_prompt,
    :refined_prompt,
    :summary,
    :scores_before,
    :scores_after,
    :original_sha256,
    :refined_sha256,
    version: @version,
    changes: [],
    questions: [],
    warnings: [],
    safety: @default_safety,
    metadata: %{}
  ]

  @type score_entry :: %{required(binary()) => pos_integer() | binary()}
  @type t :: %__MODULE__{
          id: binary(),
          version: binary(),
          preset_id: binary(),
          preset_version: binary(),
          status: binary(),
          original_prompt: binary(),
          refined_prompt: binary(),
          summary: binary(),
          scores_before: %{required(binary()) => score_entry()},
          scores_after: %{required(binary()) => score_entry()},
          changes: [map()],
          questions: [binary()],
          warnings: [binary()],
          safety: map(),
          metadata: map(),
          original_sha256: binary(),
          refined_sha256: binary()
        }

  @doc "Returns the refinement contract version."
  @spec version() :: binary()
  def version, do: @version

  @doc "Builds a validated refiner result from atom or string keyed attrs."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Schema.attrs_map(attrs)

    with :ok <- reject_unknown_fields(attrs),
         {:ok, version} <-
           Schema.optional_binary(attrs, :version, @version, :invalid_refinement_version),
         :ok <- validate_version(version),
         {:ok, preset_id} <-
           Schema.required_binary(attrs, :preset_id, {:invalid_refinement, :preset_id}),
         {:ok, preset_id} <- Schema.validate_id(preset_id, {:invalid_refinement, :preset_id}),
         {:ok, preset_version} <-
           Schema.optional_binary(
             attrs,
             :preset_version,
             Preset.version(),
             {:invalid_refinement, :preset_version}
           ),
         {:ok, status} <- status(attrs),
         {:ok, original_prompt} <-
           Schema.required_binary(
             attrs,
             :original_prompt,
             {:invalid_refinement, :original_prompt}
           ),
         {:ok, refined_prompt} <-
           Schema.required_binary(attrs, :refined_prompt, {:invalid_refinement, :refined_prompt}),
         {:ok, summary} <-
           Schema.required_binary(attrs, :summary, {:invalid_refinement, :summary}),
         {:ok, scores_before} <- score_map(attrs, :scores_before),
         {:ok, scores_after} <- score_map(attrs, :scores_after),
         {:ok, changes} <- changes(attrs),
         {:ok, questions} <-
           Schema.optional_string_list(attrs, :questions, [], {:invalid_refinement, :questions}),
         {:ok, warnings} <-
           Schema.optional_string_list(attrs, :warnings, [], {:invalid_refinement, :warnings}),
         {:ok, safety} <- safety(attrs),
         {:ok, metadata} <- Schema.metadata(attrs, :metadata, :invalid_refinement_metadata),
         {:ok, original_sha256} <- hash_field(attrs, :original_sha256, original_prompt),
         {:ok, refined_sha256} <- hash_field(attrs, :refined_sha256, refined_prompt),
         {:ok, id} <- optional_id(attrs, preset_id, status, original_sha256, refined_sha256) do
      {:ok,
       %__MODULE__{
         id: id,
         version: version,
         preset_id: preset_id,
         preset_version: preset_version,
         status: status,
         original_prompt: original_prompt,
         refined_prompt: refined_prompt,
         summary: summary,
         scores_before: scores_before,
         scores_after: scores_after,
         changes: changes,
         questions: questions,
         warnings: warnings,
         safety: safety,
         metadata: metadata,
         original_sha256: original_sha256,
         refined_sha256: refined_sha256
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_refinement}

  @doc "Converts decoded JSON-ish data back to a refinement."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Returns a JSON-friendly refinement map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = refinement) do
    %{
      id: refinement.id,
      version: refinement.version,
      preset_id: refinement.preset_id,
      preset_version: refinement.preset_version,
      status: refinement.status,
      original_prompt: refinement.original_prompt,
      refined_prompt: refinement.refined_prompt,
      summary: refinement.summary,
      scores_before: refinement.scores_before,
      scores_after: refinement.scores_after,
      changes: refinement.changes,
      questions: refinement.questions,
      warnings: refinement.warnings,
      safety: refinement.safety,
      metadata: refinement.metadata,
      original_sha256: refinement.original_sha256,
      refined_sha256: refinement.refined_sha256
    }
  end

  @doc "Returns redacted debug data without raw prompt text."
  @spec debug(t()) :: map()
  def debug(%__MODULE__{} = refinement) do
    %{
      id: refinement.id,
      version: refinement.version,
      preset_id: refinement.preset_id,
      preset_version: refinement.preset_version,
      status: refinement.status,
      original_sha256: refinement.original_sha256,
      refined_sha256: refinement.refined_sha256,
      scores_before: refinement.scores_before,
      scores_after: refinement.scores_after,
      change_count: length(refinement.changes),
      question_count: length(refinement.questions),
      warning_count: length(refinement.warnings),
      safety: refinement.safety,
      metadata: Tet.Redactor.redact(refinement.metadata)
    }
  end

  @doc "Returns a stable line-oriented debug snapshot without prompt content."
  @spec debug_text(t()) :: binary()
  def debug_text(%__MODULE__{} = refinement) do
    debug = debug(refinement)

    [
      "#{debug.version} id=#{debug.id} preset=#{debug.preset_id} status=#{debug.status}",
      "original_sha256=#{debug.original_sha256} refined_sha256=#{debug.refined_sha256}",
      "scores_before=#{Canonical.encode(debug.scores_before)}",
      "scores_after=#{Canonical.encode(debug.scores_after)}",
      "changes=#{debug.change_count} questions=#{debug.question_count} warnings=#{debug.warning_count} safety=#{Canonical.encode(debug.safety)} metadata=#{Canonical.encode(debug.metadata)}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp reject_unknown_fields(attrs) do
    attrs
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case key_name(key) do
        {:ok, name} when name in @allowed_fields -> {:cont, :ok}
        {:ok, name} -> {:halt, {:error, {:invalid_refinement_field, name}}}
        :error -> {:halt, {:error, {:invalid_refinement_field, inspect(key)}}}
      end
    end)
  end

  defp validate_version(@version), do: :ok
  defp validate_version(_version), do: {:error, :invalid_refinement_version}

  defp status(attrs) do
    with {:ok, status} <- Schema.required_binary(attrs, :status, {:invalid_refinement, :status}) do
      if status in @statuses do
        {:ok, status}
      else
        {:error, {:invalid_refinement, :status}}
      end
    end
  end

  defp score_map(attrs, key) do
    case Schema.fetch_value(attrs, key) do
      value when is_map(value) and map_size(value) > 0 ->
        value
        |> Enum.reduce_while({:ok, %{}}, fn {dimension, entry}, {:ok, acc} ->
          with {:ok, dimension} <- dimension_id(dimension, key),
               {:ok, entry} <- score_entry(entry, key, dimension) do
            {:cont, {:ok, Map.put(acc, dimension, entry)}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      _value ->
        {:error, {:invalid_refinement, key}}
    end
  end

  defp dimension_id(dimension, _key) when is_binary(dimension) and dimension != "",
    do: {:ok, dimension}

  defp dimension_id(dimension, _key) when is_atom(dimension), do: {:ok, Atom.to_string(dimension)}
  defp dimension_id(_dimension, key), do: {:error, {:invalid_refinement_score, key}}

  defp score_entry(entry, key, dimension) when is_map(entry) do
    score = Schema.fetch_value(entry, :score)
    comment = Schema.fetch_value(entry, :comment)

    cond do
      not (is_integer(score) and score >= 1 and score <= 10) ->
        {:error, {:invalid_refinement_score, key, dimension, :score}}

      not (is_binary(comment) and String.trim(comment) != "") ->
        {:error, {:invalid_refinement_score, key, dimension, :comment}}

      true ->
        {:ok, %{"score" => score, "comment" => String.trim(comment)}}
    end
  end

  defp score_entry(_entry, key, _dimension), do: {:error, {:invalid_refinement_score, key}}

  defp changes(attrs) do
    case Schema.fetch_value(attrs, :changes, []) do
      changes when is_list(changes) -> normalize_changes(changes)
      _changes -> {:error, {:invalid_refinement, :changes}}
    end
  end

  defp normalize_changes(changes) do
    changes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {change, index}, {:ok, acc} ->
      case normalize_change(change, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_change(change, index) when is_map(change) do
    with :ok <- reject_unknown_change_fields(change, index),
         {:ok, dimension} <- required_change_binary(change, :dimension, index),
         {:ok, kind} <- required_change_binary(change, :kind, index),
         {:ok, rationale} <- required_change_binary(change, :rationale, index),
         {:ok, impact} <- optional_change_binary(change, :impact, "medium", index) do
      {:ok,
       %{
         "dimension" => dimension,
         "kind" => kind,
         "rationale" => rationale,
         "impact" => impact
       }}
    end
  end

  defp normalize_change(_change, index), do: {:error, {:invalid_refinement_change, index}}

  defp reject_unknown_change_fields(change, index) do
    change
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case key_name(key) do
        {:ok, name} when name in @change_fields -> {:cont, :ok}
        {:ok, name} -> {:halt, {:error, {:invalid_refinement_change_field, index, name}}}
        :error -> {:halt, {:error, {:invalid_refinement_change_field, index, inspect(key)}}}
      end
    end)
  end

  defp required_change_binary(change, key, index),
    do: Schema.required_binary(change, key, {:invalid_refinement_change, index, key})

  defp optional_change_binary(change, key, default, index),
    do: Schema.optional_binary(change, key, default, {:invalid_refinement_change, index, key})

  defp safety(attrs) do
    attrs
    |> Schema.fetch_value(:safety, @default_safety)
    |> Schema.normalize_metadata(:invalid_refinement_safety)
    |> case do
      {:ok, safety} -> validate_safety(safety)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_safety(safety) do
    if Enum.all?(@default_safety, fn {key, expected} -> Map.get(safety, key) == expected end) do
      {:ok, safety}
    else
      {:error, :invalid_refinement_safety}
    end
  end

  defp hash_field(attrs, key, prompt) do
    expected = Schema.hash_text(prompt)

    case Schema.fetch_value(attrs, key, expected) do
      ^expected -> {:ok, expected}
      _hash -> {:error, {:invalid_refinement, key}}
    end
  end

  defp optional_id(attrs, preset_id, status, original_sha256, refined_sha256) do
    generated =
      Schema.generated_id("prompt-refinement-", %{
        original_sha256: original_sha256,
        preset_id: preset_id,
        refined_sha256: refined_sha256,
        status: status
      })

    case Schema.fetch_value(attrs, :id, generated) do
      nil -> {:ok, generated}
      id when is_binary(id) -> Schema.validate_id(id, {:invalid_refinement, :id})
      id when is_atom(id) -> Schema.validate_id(id, {:invalid_refinement, :id})
      _id -> {:error, {:invalid_refinement, :id}}
    end
  end

  defp key_name(key) when is_binary(key), do: {:ok, key}
  defp key_name(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp key_name(_key), do: :error
end
