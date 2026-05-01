defmodule Tet.Artifact do
  @moduledoc """
  Core artifact entity for content-addressed runtime outputs.

  Small artifacts may be inline; large artifacts live under `.tet/artifacts/`
  and are referenced by path plus sha256. The sha is mandatory either way.
  """

  alias Tet.Entity

  @kinds [:diff, :stdout, :stderr, :file_snapshot, :prompt_debug, :provider_payload]

  @enforce_keys [:id, :session_id, :kind, :sha256, :created_at]
  defstruct [:id, :session_id, :kind, :content, :path, :sha256, :created_at, metadata: %{}]

  @type kind :: :diff | :stdout | :stderr | :file_snapshot | :prompt_debug | :provider_payload
  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          kind: kind(),
          content: binary() | nil,
          path: String.t() | nil,
          sha256: String.t(),
          created_at: DateTime.t(),
          metadata: map()
        }

  @doc "Returns accepted artifact kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Builds an artifact from atom- or string-keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :artifact),
         {:ok, session_id} <- Entity.fetch_required_binary(attrs, :session_id, :artifact),
         {:ok, kind} <- Entity.fetch_atom(attrs, :kind, @kinds, :artifact),
         {:ok, content} <- Entity.fetch_binary_or_nil(attrs, :content, :artifact),
         {:ok, path} <- Entity.fetch_optional_binary(attrs, :path, :artifact),
         :ok <- ensure_location(content, path),
         {:ok, sha256} <- Entity.fetch_sha256(attrs, :sha256, :artifact),
         {:ok, created_at} <- Entity.fetch_required_datetime(attrs, :created_at, :artifact),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :artifact) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         kind: kind,
         content: content,
         path: path,
         sha256: sha256,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_artifact}

  @doc "Converts a decoded map back to an artifact."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Converts the artifact to a map with stable string enums and timestamps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = artifact) do
    %{
      id: artifact.id,
      session_id: artifact.session_id,
      kind: Atom.to_string(artifact.kind),
      content: artifact.content,
      path: artifact.path,
      sha256: artifact.sha256,
      created_at: Entity.datetime_to_map(artifact.created_at),
      metadata: artifact.metadata
    }
  end

  defp ensure_location(nil, nil), do: Entity.value_error(:artifact, :content)

  defp ensure_location(content, path) when is_binary(content) and is_binary(path),
    do: Entity.value_error(:artifact, :path)

  defp ensure_location(_content, _path), do: :ok
end
