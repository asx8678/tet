defmodule Tet.Store.SQLite.Schema.Finding do
  @moduledoc """
  Ecto schema for the `findings` SQLite table.

  Maps to/from the `Tet.Finding` core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "findings" do
    field(:session_id, :string)
    field(:task_id, :string)
    field(:title, :string)
    field(:description, :string)
    field(:source, :string)
    field(:severity, :string, default: "info")
    field(:evidence_refs, :binary)
    field(:promoted_to, :binary)
    field(:promoted_at, :integer)
    field(:status, :string, default: "open")
    field(:metadata, :binary)
    field(:created_at, :integer)
  end

  @required ~w(id session_id title source severity status created_at)a
  @optional ~w(task_id description evidence_refs promoted_to promoted_at metadata)a

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:source, ~w(event tool_run failure review verifier repair manual))
    |> validate_inclusion(:severity, ~w(info warning critical))
    |> validate_inclusion(:status, ~w(open promoted dismissed))
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:task_id)
  end

  @spec to_core_struct(%__MODULE__{}) :: Tet.Finding.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.Finding{
      id: row.id,
      session_id: row.session_id,
      task_id: row.task_id,
      title: row.title,
      description: row.description,
      source: String.to_existing_atom(row.source),
      severity: String.to_existing_atom(row.severity),
      evidence_refs: JsonField.decode_list(row.evidence_refs),
      promoted_to: decode_promoted_to(row.promoted_to),
      promoted_at: JsonField.to_datetime(row.promoted_at),
      status: String.to_existing_atom(row.status),
      created_at: JsonField.to_datetime(row.created_at),
      metadata: JsonField.decode(row.metadata)
    }
  end

  @spec from_core_struct(Tet.Finding.t()) :: map()
  def from_core_struct(%Tet.Finding{} = core) do
    %{
      id: core.id,
      session_id: core.session_id,
      task_id: core.task_id,
      title: core.title,
      description: core.description,
      source: Atom.to_string(core.source),
      severity: safe_atom_to_string(core.severity, "info"),
      evidence_refs: encode_optional_list(core.evidence_refs),
      promoted_to: encode_promoted_to(core.promoted_to),
      promoted_at: JsonField.from_datetime(core.promoted_at),
      status: Atom.to_string(core.status),
      created_at: JsonField.from_datetime(core.created_at),
      metadata: JsonField.encode(core.metadata)
    }
  end

  defp safe_atom_to_string(nil, default), do: default
  defp safe_atom_to_string(atom, _default) when is_atom(atom), do: Atom.to_string(atom)

  defp encode_optional_list(nil), do: nil
  defp encode_optional_list(list) when is_list(list), do: JsonField.encode(list)

  defp encode_promoted_to(nil), do: nil

  defp encode_promoted_to({type, id}) when is_atom(type) and is_binary(id) do
    Jason.encode!(%{type: Atom.to_string(type), id: id})
  end

  defp decode_promoted_to(nil), do: nil

  defp decode_promoted_to(blob) when is_binary(blob) do
    case Jason.decode(blob) do
      {:ok, %{"type" => type_str, "id" => id}}
      when type_str in ~w(persistent_memory project_lesson) ->
        {String.to_existing_atom(type_str), id}

      _ ->
        nil
    end
  end
end
