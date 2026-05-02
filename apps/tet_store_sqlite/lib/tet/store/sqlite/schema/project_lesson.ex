defmodule Tet.Store.SQLite.Schema.ProjectLesson do
  @moduledoc """
  Ecto schema for the `project_lessons` SQLite table.

  Maps to/from the `Tet.ProjectLesson` core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "project_lessons" do
    field(:title, :string)
    field(:description, :string)
    field(:category, :string)
    field(:source_finding_id, :string)
    field(:session_id, :string)
    field(:evidence_refs, :binary)
    field(:promoted_at, :integer)
    field(:metadata, :binary)
    field(:created_at, :integer)
  end

  @required ~w(id title source_finding_id created_at)a
  @optional ~w(description category session_id evidence_refs promoted_at metadata)a

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(
      :category,
      [nil | ~w(convention repair_strategy error_pattern verification performance security)]
    )
    |> foreign_key_constraint(:session_id)
  end

  @spec to_core_struct(%__MODULE__{}) :: Tet.ProjectLesson.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.ProjectLesson{
      id: row.id,
      title: row.title,
      description: row.description,
      category: safe_to_existing_atom(row.category),
      source_finding_id: row.source_finding_id,
      session_id: row.session_id,
      evidence_refs: JsonField.decode_list(row.evidence_refs),
      promoted_at: JsonField.to_datetime(row.promoted_at),
      created_at: JsonField.to_datetime(row.created_at),
      metadata: JsonField.decode(row.metadata)
    }
  end

  @spec from_core_struct(Tet.ProjectLesson.t()) :: map()
  def from_core_struct(%Tet.ProjectLesson{} = core) do
    %{
      id: core.id,
      title: core.title,
      description: core.description,
      category: safe_atom_to_string(core.category),
      source_finding_id: core.source_finding_id,
      session_id: core.session_id,
      evidence_refs: encode_optional_list(core.evidence_refs),
      promoted_at: JsonField.from_datetime(core.promoted_at),
      created_at: JsonField.from_datetime(core.created_at),
      metadata: JsonField.encode(core.metadata)
    }
  end

  defp safe_to_existing_atom(nil), do: nil
  defp safe_to_existing_atom(str) when is_binary(str), do: String.to_existing_atom(str)

  defp safe_atom_to_string(nil), do: nil
  defp safe_atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp encode_optional_list(nil), do: nil
  defp encode_optional_list(list) when is_list(list), do: JsonField.encode(list)
end
