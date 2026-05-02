defmodule Tet.Store.SQLite.Schema.Artifact do
  @moduledoc """
  Ecto schema for the `artifacts` SQLite table.

  Maps to/from the `Tet.Artifact` core struct.

  Field mapping:
    - DB `inline_blob` → core `content`
    - DB `workspace_id`, `short_id`, `size_bytes` are DB-only
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "artifacts" do
    field(:workspace_id, :string)
    field(:session_id, :string)
    field(:short_id, :string)
    field(:kind, :string)
    field(:sha256, :string)
    field(:size_bytes, :integer)
    field(:inline_blob, :binary)
    field(:path, :string)
    field(:metadata, :binary)
    field(:created_at, :integer)
  end

  @required ~w(id workspace_id kind sha256 size_bytes created_at)a
  @optional ~w(session_id short_id inline_blob path metadata)a

  @doc "Builds a changeset for inserting an artifact."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(
      :kind,
      ~w(diff stdout stderr file_snapshot prompt_debug provider_payload)
    )
    |> validate_length(:sha256, is: 64)
    |> validate_number(:size_bytes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:session_id)
    |> unique_constraint([:workspace_id, :sha256])
    |> unique_constraint([:workspace_id, :short_id])
  end

  @doc "Converts an Ecto schema row to a `Tet.Artifact` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.Artifact.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.Artifact{
      id: row.id,
      session_id: row.session_id,
      kind: String.to_existing_atom(row.kind),
      content: row.inline_blob,
      path: row.path,
      sha256: row.sha256,
      metadata: JsonField.decode(row.metadata),
      created_at: JsonField.to_datetime(row.created_at)
    }
  end

  @doc "Converts a `Tet.Artifact` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.Artifact.t(), keyword()) :: map()
  def from_core_struct(%Tet.Artifact{} = core, opts \\ []) do
    %{
      id: core.id,
      workspace_id: Keyword.get(opts, :workspace_id),
      session_id: core.session_id,
      kind: Atom.to_string(core.kind),
      sha256: core.sha256,
      size_bytes: compute_size(core.content),
      inline_blob: core.content,
      path: core.path,
      metadata: JsonField.encode(core.metadata),
      created_at: JsonField.from_datetime(core.created_at)
    }
  end

  defp compute_size(nil), do: 0
  defp compute_size(blob) when is_binary(blob), do: byte_size(blob)
end
