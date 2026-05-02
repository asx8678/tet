defmodule Tet.Store.SQLite.Schema.Workflow do
  @moduledoc """
  Ecto schema for the `workflows` SQLite table.

  Maps to/from the `Tet.Workflow` core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "workflows" do
    field(:session_id, :string)
    field(:task_id, :string)
    field(:status, :string)
    field(:claimed_by, :string)
    field(:claim_expires_at, :integer)
    field(:metadata, :binary)
    field(:created_at, :integer)
    field(:updated_at, :integer)
  end

  @required ~w(id session_id status created_at updated_at)a
  @optional ~w(task_id claimed_by claim_expires_at metadata)a

  @doc "Builds a changeset for inserting or updating a workflow."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(
      :status,
      ~w(running paused_for_approval completed failed cancelled)
    )
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:task_id)
  end

  @doc "Converts an Ecto schema row to a `Tet.Workflow` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.Workflow.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.Workflow{
      id: row.id,
      session_id: row.session_id,
      task_id: row.task_id,
      status: String.to_existing_atom(row.status),
      claimed_by: row.claimed_by,
      claim_expires_at: JsonField.to_datetime(row.claim_expires_at),
      metadata: JsonField.decode(row.metadata),
      created_at: JsonField.to_datetime(row.created_at),
      updated_at: JsonField.to_datetime(row.updated_at)
    }
  end

  @doc "Converts a `Tet.Workflow` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.Workflow.t()) :: map()
  def from_core_struct(%Tet.Workflow{} = core) do
    %{
      id: core.id,
      session_id: core.session_id,
      task_id: core.task_id,
      status: Atom.to_string(core.status),
      claimed_by: core.claimed_by,
      claim_expires_at: JsonField.from_datetime(core.claim_expires_at),
      metadata: JsonField.encode(core.metadata),
      created_at: JsonField.from_datetime(core.created_at),
      updated_at: JsonField.from_datetime(core.updated_at)
    }
  end
end
