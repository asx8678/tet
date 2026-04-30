defmodule Tet.PromptLab.HistoryEntry do
  @moduledoc """
  Prompt Lab history entry contract.

  History entries are the only persistence shape Prompt Lab owns in BD-0047.
  They record explicit request/result data for review, dashboards, and audit
  trails without touching chat messages, autosaves, timeline events, or tools.
  """

  alias Tet.PromptLab.{Refinement, Request, Schema}

  @version "tet.prompt_lab.history.v1"

  @enforce_keys [:id, :created_at, :request, :result]
  defstruct [:id, :created_at, :request, :result, version: @version, metadata: %{}]

  @type t :: %__MODULE__{
          id: binary(),
          version: binary(),
          created_at: binary(),
          request: Request.t(),
          result: Refinement.t(),
          metadata: map()
        }

  @doc "Returns the prompt-history contract version."
  @spec version() :: binary()
  def version, do: @version

  @doc "Builds a validated Prompt Lab history entry."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Schema.attrs_map(attrs)

    with {:ok, version} <-
           Schema.optional_binary(attrs, :version, @version, :invalid_history_version),
         :ok <- validate_version(version),
         {:ok, created_at} <-
           Schema.required_binary(attrs, :created_at, {:invalid_history, :created_at}),
         {:ok, request} <- request(attrs),
         {:ok, result} <- result(attrs),
         {:ok, metadata} <- Schema.metadata(attrs, :metadata, :invalid_history_metadata),
         {:ok, id} <- optional_id(attrs, created_at, request, result) do
      {:ok,
       %__MODULE__{
         id: id,
         version: version,
         created_at: created_at,
         request: request,
         result: result,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_history}

  @doc "Converts decoded JSON-ish data back to a history entry."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Returns a JSON-friendly prompt-history map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = history) do
    %{
      id: history.id,
      version: history.version,
      created_at: history.created_at,
      request: Request.to_map(history.request),
      result: Refinement.to_map(history.result),
      metadata: history.metadata
    }
  end

  @doc "Returns redacted debug data without raw prompt text."
  @spec debug(t()) :: map()
  def debug(%__MODULE__{} = history) do
    %{
      id: history.id,
      version: history.version,
      created_at: history.created_at,
      request: %{
        version: history.request.version,
        preset_id: history.request.preset_id,
        dimensions: history.request.dimensions,
        prompt_sha256: Schema.hash_text(history.request.prompt),
        metadata: Tet.Redactor.redact(history.request.metadata)
      },
      result: Refinement.debug(history.result),
      metadata: Tet.Redactor.redact(history.metadata)
    }
  end

  defp validate_version(@version), do: :ok
  defp validate_version(_version), do: {:error, :invalid_history_version}

  defp request(attrs) do
    case Schema.fetch_value(attrs, :request) do
      %Request{} = request -> {:ok, request}
      request when is_map(request) -> Request.from_map(request)
      _request -> {:error, {:invalid_history, :request}}
    end
  end

  defp result(attrs) do
    case Schema.fetch_value(attrs, :result) do
      %Refinement{} = result -> {:ok, result}
      result when is_map(result) -> Refinement.from_map(result)
      _result -> {:error, {:invalid_history, :result}}
    end
  end

  defp optional_id(attrs, created_at, request, result) do
    generated =
      Schema.generated_id("prompt-history-", %{
        created_at: created_at,
        preset_id: request.preset_id,
        prompt_sha256: Schema.hash_text(request.prompt),
        result_id: result.id
      })

    case Schema.fetch_value(attrs, :id, generated) do
      nil -> {:ok, generated}
      id when is_binary(id) -> Schema.validate_id(id, {:invalid_history, :id})
      id when is_atom(id) -> Schema.validate_id(id, {:invalid_history, :id})
      _id -> {:error, {:invalid_history, :id}}
    end
  end
end
