defmodule Tet.Workspace do
  @moduledoc """
  Core workspace entity for the v0.3 store contract.

  Stores map their schemas to this struct at the core boundary. IDs are opaque
  strings in the contract so current prefixed runtime IDs and future UUIDs both
  fit without turning the type spec into a bouncer with a fake mustache.
  """

  alias Tet.Entity

  @trust_states [:untrusted, :trusted]

  @enforce_keys [:id, :name, :root_path, :tet_dir_path, :trust_state, :created_at, :updated_at]
  defstruct [
    :id,
    :name,
    :root_path,
    :tet_dir_path,
    :trust_state,
    :created_at,
    :updated_at,
    metadata: %{}
  ]

  @type trust_state :: :untrusted | :trusted
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          root_path: String.t(),
          tet_dir_path: String.t(),
          trust_state: trust_state(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          metadata: map()
        }

  @doc "Returns accepted workspace trust states."
  @spec trust_states() :: [trust_state()]
  def trust_states, do: @trust_states

  @doc "Builds a workspace from atom- or string-keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- Entity.fetch_required_binary(attrs, :id, :workspace),
         {:ok, name} <- Entity.fetch_required_binary(attrs, :name, :workspace),
         {:ok, root_path} <- Entity.fetch_required_binary(attrs, :root_path, :workspace),
         {:ok, tet_dir_path} <- Entity.fetch_required_binary(attrs, :tet_dir_path, :workspace),
         {:ok, trust_state} <- Entity.fetch_atom(attrs, :trust_state, @trust_states, :workspace),
         {:ok, created_at} <- Entity.fetch_required_datetime(attrs, :created_at, :workspace),
         {:ok, updated_at} <- Entity.fetch_required_datetime(attrs, :updated_at, :workspace),
         {:ok, metadata} <- Entity.fetch_map(attrs, :metadata, :workspace) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         root_path: root_path,
         tet_dir_path: tet_dir_path,
         trust_state: trust_state,
         created_at: created_at,
         updated_at: updated_at,
         metadata: metadata
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_workspace}

  @doc "Converts a decoded map back to a workspace."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Converts the workspace to a map with stable string enums and timestamps."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = workspace) do
    %{
      id: workspace.id,
      name: workspace.name,
      root_path: workspace.root_path,
      tet_dir_path: workspace.tet_dir_path,
      trust_state: Atom.to_string(workspace.trust_state),
      created_at: Entity.datetime_to_map(workspace.created_at),
      updated_at: Entity.datetime_to_map(workspace.updated_at),
      metadata: workspace.metadata
    }
  end
end
