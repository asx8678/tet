defmodule Tet.Store.SQLite.Schema.PersistentMemory do
  @moduledoc """
  Ecto schema for the `persistent_memories` SQLite table.

  Maps to/from the `Tet.PersistentMemory` core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "persistent_memories" do
    field(:session_id, :string)
    field(:title, :string)
    field(:description, :string)
    field(:source_finding_id, :string)
    field(:severity, :string)
    field(:evidence_refs, :binary)
    field(:promoted_at, :integer)
    field(:metadata, :binary)
    field(:created_at, :integer)
  end

  @required ~w(id session_id title source_finding_id created_at)a
  @optional ~w(description severity evidence_refs promoted_at metadata)a

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:severity, [nil | ~w(info warning critical)])
    |> foreign_key_constraint(:session_id)
  end

  @spec to_core_struct(%__MODULE__{}) :: Tet.PersistentMemory.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.PersistentMemory{
      id: row.id,
      session_id: row.session_id,
      title: row.title,
      description: row.description,
      source_finding_id: row.source_finding_id,
      severity: safe_to_existing_atom(row.severity),
      evidence_refs: JsonField.decode_list(row.evidence_refs),
      promoted_at: JsonField.to_datetime(row.promoted_at),
      created_at: JsonField.to_datetime(row.created_at),
      metadata: JsonField.decode(row.metadata)
    }
  end

  @spec from_core_struct(Tet.PersistentMemory.t()) :: map()
  def from_core_struct(%Tet.PersistentMemory{} = core) do
    %{
      id: core.id,
      session_id: core.session_id,
      title: core.title,
      description: core.description,
      source_finding_id: core.source_finding_id,
      severity: safe_atom_to_string(core.severity),
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
