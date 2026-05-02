defmodule Tet.Store.SQLite.Schema.Checkpoint do
  @moduledoc """
  Ecto schema for the `checkpoints` SQLite table.

  Maps to/from the `Tet.Checkpoint` core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "checkpoints" do
    field(:session_id, :string)
    field(:task_id, :string)
    field(:workflow_id, :string)
    field(:sha256, :string)
    field(:state_snapshot, :binary)
    field(:metadata, :binary)
    field(:created_at, :integer)
  end

  @required ~w(id session_id created_at)a
  @optional ~w(task_id workflow_id sha256 state_snapshot metadata)a

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:workflow_id)
  end

  @spec to_core_struct(%__MODULE__{}) :: Tet.Checkpoint.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.Checkpoint{
      id: row.id,
      session_id: row.session_id,
      task_id: row.task_id,
      workflow_id: row.workflow_id,
      sha256: row.sha256,
      state_snapshot: JsonField.decode_any(row.state_snapshot),
      created_at: unix_to_iso(row.created_at),
      metadata: JsonField.decode(row.metadata)
    }
  end

  @spec from_core_struct(Tet.Checkpoint.t()) :: map()
  def from_core_struct(%Tet.Checkpoint{} = core) do
    %{
      id: core.id,
      session_id: core.session_id,
      task_id: core.task_id,
      workflow_id: core.workflow_id,
      sha256: core.sha256,
      state_snapshot: encode_optional(core.state_snapshot),
      created_at: iso_to_unix(core.created_at),
      metadata: JsonField.encode(core.metadata)
    }
  end

  defp unix_to_iso(nil), do: nil

  defp unix_to_iso(unix) when is_integer(unix),
    do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp iso_to_unix(nil), do: DateTime.to_unix(DateTime.utc_now())

  defp iso_to_unix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> DateTime.to_unix(DateTime.utc_now())
    end
  end

  defp iso_to_unix(unix) when is_integer(unix), do: unix

  defp encode_optional(nil), do: nil
  defp encode_optional(value), do: JsonField.encode(value)
end
