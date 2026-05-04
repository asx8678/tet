defmodule Tet.Store.SQLite.Schema.Workspace do
  @moduledoc """
  Ecto schema for the `workspaces` SQLite table.

  Maps to/from the `Tet.Workspace` core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "workspaces" do
    field(:name, :string)
    field(:root_path, :string)
    field(:tet_dir_path, :string)
    field(:trust_state, :string)
    field(:metadata, :binary)
    field(:created_at, :integer)
    field(:updated_at, :integer)
  end

  @required ~w(id name root_path tet_dir_path trust_state created_at updated_at)a
  @optional ~w(metadata)a

  @doc "Builds a changeset for inserting or updating a workspace."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:trust_state, ~w(untrusted trusted))
    |> unique_constraint(:root_path)
  end

  @doc "Converts an Ecto schema row to a `Tet.Workspace` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.Workspace.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.Workspace{
      id: row.id,
      name: row.name,
      root_path: row.root_path,
      tet_dir_path: row.tet_dir_path,
      trust_state: String.to_atom(row.trust_state),
      metadata: JsonField.decode(row.metadata),
      created_at: JsonField.to_datetime(row.created_at),
      updated_at: JsonField.to_datetime(row.updated_at)
    }
  end

  @doc "Converts a `Tet.Workspace` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.Workspace.t()) :: map()
  def from_core_struct(%Tet.Workspace{} = core) do
    %{
      id: core.id,
      name: core.name,
      root_path: core.root_path,
      tet_dir_path: core.tet_dir_path,
      trust_state: Atom.to_string(core.trust_state),
      metadata: JsonField.encode(core.metadata),
      created_at: JsonField.from_datetime(core.created_at),
      updated_at: JsonField.from_datetime(core.updated_at)
    }
  end
end
