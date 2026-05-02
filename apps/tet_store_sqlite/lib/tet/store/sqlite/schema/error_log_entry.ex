defmodule Tet.Store.SQLite.Schema.ErrorLogEntry do
  @moduledoc """
  Ecto schema for the `error_log` SQLite table.

  Maps to/from the `Tet.ErrorLog` core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "error_log" do
    field(:session_id, :string)
    field(:task_id, :string)
    field(:kind, :string)
    field(:message, :string)
    field(:stacktrace, :string)
    field(:context, :binary)
    field(:status, :string, default: "open")
    field(:resolved_at, :integer)
    field(:metadata, :binary)
    field(:created_at, :integer)
  end

  @required ~w(id session_id kind message status created_at)a
  @optional ~w(task_id stacktrace context resolved_at metadata)a

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, ~w(open resolved dismissed))
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:task_id)
  end

  @spec to_core_struct(%__MODULE__{}) :: Tet.ErrorLog.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.ErrorLog{
      id: row.id,
      session_id: row.session_id,
      task_id: row.task_id,
      kind: safe_to_existing_atom(row.kind),
      message: row.message,
      stacktrace: row.stacktrace,
      context: JsonField.decode_any(row.context),
      status: String.to_existing_atom(row.status),
      resolved_at: JsonField.to_datetime(row.resolved_at),
      created_at: JsonField.to_datetime(row.created_at),
      metadata: JsonField.decode(row.metadata)
    }
  end

  @spec from_core_struct(Tet.ErrorLog.t()) :: map()
  def from_core_struct(%Tet.ErrorLog{} = core) do
    %{
      id: core.id,
      session_id: core.session_id,
      task_id: core.task_id,
      kind: Atom.to_string(core.kind),
      message: core.message,
      stacktrace: core.stacktrace,
      context: encode_optional(core.context),
      status: Atom.to_string(core.status),
      resolved_at: JsonField.from_datetime(core.resolved_at),
      created_at: JsonField.from_datetime(core.created_at),
      metadata: JsonField.encode(core.metadata)
    }
  end

  defp safe_to_existing_atom(nil), do: nil
  defp safe_to_existing_atom(str) when is_binary(str), do: String.to_existing_atom(str)

  defp encode_optional(nil), do: nil
  defp encode_optional(value), do: JsonField.encode(value)
end
