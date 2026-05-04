defmodule Tet.Store.SQLite.Schema.Event do
  @moduledoc """
  Ecto schema for the `events` SQLite table.

  Maps to/from the `Tet.Event` core struct.

  Field mapping:
    - DB `inserted_at` → core `created_at`
    - DB `seq`         → core `seq` and `sequence`
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "events" do
    field(:session_id, :string)
    field(:seq, :integer)
    field(:type, :string)
    field(:payload, :binary)
    field(:metadata, :binary)
    field(:inserted_at, :integer)
  end

  @required ~w(id session_id seq type inserted_at)a
  @optional ~w(payload metadata)a

  @doc "Builds a changeset for inserting an event."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:seq, greater_than: 0)
    |> foreign_key_constraint(:session_id)
    |> unique_constraint([:session_id, :seq])
  end

  @doc "Converts an Ecto schema row to a `Tet.Event` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.Event.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.Event{
      id: row.id,
      type: String.to_atom(row.type),
      session_id: row.session_id,
      seq: row.seq,
      sequence: row.seq,
      payload: JsonField.decode(row.payload),
      metadata: JsonField.decode(row.metadata),
      created_at: JsonField.to_datetime(row.inserted_at)
    }
  end

  @doc "Converts a `Tet.Event` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.Event.t()) :: map()
  def from_core_struct(%Tet.Event{} = core) do
    %{
      id: core.id,
      session_id: core.session_id,
      seq: core.seq || core.sequence,
      type: Atom.to_string(core.type),
      payload: JsonField.encode(core.payload),
      metadata: JsonField.encode(core.metadata),
      inserted_at: resolve_inserted_at(core)
    }
  end

  defp resolve_inserted_at(%Tet.Event{created_at: %DateTime{} = dt}),
    do: DateTime.to_unix(dt)

  defp resolve_inserted_at(%Tet.Event{created_at: iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp resolve_inserted_at(_), do: nil
end
