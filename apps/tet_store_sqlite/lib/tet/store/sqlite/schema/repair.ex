defmodule Tet.Store.SQLite.Schema.Repair do
  @moduledoc """
  Ecto schema for the `repairs` SQLite table.

  Maps to/from the `Tet.Repair` core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "repairs" do
    field :error_log_id, :string
    field :session_id, :string
    field :strategy, :string
    field :params, :binary
    field :result, :binary
    field :status, :string, default: "pending"
    field :metadata, :binary
    field :created_at, :integer
    field :started_at, :integer
    field :completed_at, :integer
  end

  @required ~w(id error_log_id strategy status created_at)a
  @optional ~w(session_id params result metadata started_at completed_at)a

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:strategy, ~w(retry fallback patch human))
    |> validate_inclusion(:status, ~w(pending running succeeded failed skipped))
    |> foreign_key_constraint(:error_log_id)
    |> foreign_key_constraint(:session_id)
  end

  @spec to_core_struct(%__MODULE__{}) :: Tet.Repair.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.Repair{
      id: row.id,
      error_log_id: row.error_log_id,
      session_id: row.session_id,
      strategy: String.to_existing_atom(row.strategy),
      params: JsonField.decode_any(row.params),
      result: JsonField.decode_any(row.result),
      status: String.to_existing_atom(row.status),
      created_at: JsonField.to_datetime(row.created_at),
      started_at: JsonField.to_datetime(row.started_at),
      completed_at: JsonField.to_datetime(row.completed_at),
      metadata: JsonField.decode(row.metadata)
    }
  end

  @spec from_core_struct(Tet.Repair.t()) :: map()
  def from_core_struct(%Tet.Repair{} = core) do
    %{
      id: core.id,
      error_log_id: core.error_log_id,
      session_id: core.session_id,
      strategy: Atom.to_string(core.strategy),
      params: encode_optional(core.params),
      result: encode_optional(core.result),
      status: Atom.to_string(core.status),
      created_at: JsonField.from_datetime(core.created_at),
      started_at: JsonField.from_datetime(core.started_at),
      completed_at: JsonField.from_datetime(core.completed_at),
      metadata: JsonField.encode(core.metadata)
    }
  end

  defp encode_optional(nil), do: nil
  defp encode_optional(value), do: JsonField.encode(value)
end
