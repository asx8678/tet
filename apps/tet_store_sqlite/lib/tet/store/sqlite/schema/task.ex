defmodule Tet.Store.SQLite.Schema.Task do
  @moduledoc """
  Ecto schema for the `tasks` SQLite table.

  Maps to/from the `Tet.Task` core struct. DB-only fields `short_id`, `kind`,
  and `payload` are included in the schema but not mapped to the core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "tasks" do
    field(:session_id, :string)
    field(:short_id, :string)
    field(:title, :string)
    field(:kind, :string, default: "agent_task")
    field(:status, :string)
    field(:payload, :binary)
    field(:metadata, :binary)
    field(:created_at, :integer)
    field(:updated_at, :integer)
  end

  @required ~w(id session_id title status created_at updated_at)a
  @optional ~w(short_id kind payload metadata)a

  @doc "Builds a changeset for inserting or updating a task."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, ~w(active complete cancelled))
    |> foreign_key_constraint(:session_id)
    |> unique_constraint([:session_id, :short_id])
  end

  @doc "Converts an Ecto schema row to a `Tet.Task` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.Task.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.Task{
      id: row.id,
      session_id: row.session_id,
      title: row.title,
      status: String.to_atom(row.status),
      metadata: JsonField.decode(row.metadata),
      created_at: JsonField.to_datetime(row.created_at),
      updated_at: JsonField.to_datetime(row.updated_at)
    }
  end

  @doc "Converts a `Tet.Task` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.Task.t()) :: map()
  def from_core_struct(%Tet.Task{} = core) do
    %{
      id: core.id,
      session_id: core.session_id,
      title: core.title,
      status: Atom.to_string(core.status),
      metadata: JsonField.encode(core.metadata),
      created_at: JsonField.from_datetime(core.created_at),
      updated_at: JsonField.from_datetime(core.updated_at)
    }
  end
end
