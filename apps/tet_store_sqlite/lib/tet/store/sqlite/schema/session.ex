defmodule Tet.Store.SQLite.Schema.Session do
  @moduledoc """
  Ecto schema for the `sessions` SQLite table.

  Maps to/from the `Tet.Session` core struct. Note: `last_role`, `last_content`,
  and `message_count` are computed fields on the core struct — they are not
  persisted in this table.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "sessions" do
    field(:workspace_id, :string)
    field(:short_id, :string)
    field(:title, :string)
    field(:mode, :string)
    field(:status, :string)
    field(:provider, :string)
    field(:model, :string)
    field(:active_task_id, :string)
    field(:metadata, :binary)
    field(:created_at, :integer)
    field(:started_at, :integer)
    field(:updated_at, :integer)
  end

  @required ~w(id workspace_id short_id mode status created_at updated_at)a
  @optional ~w(title provider model active_task_id metadata started_at)a

  @doc "Builds a changeset for inserting or updating a session."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:mode, ~w(chat explore execute))
    |> validate_inclusion(:status, ~w(idle running waiting_approval complete error))
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :short_id])
  end

  @doc "Converts an Ecto schema row to a `Tet.Session` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.Session.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.Session{
      id: row.id,
      workspace_id: row.workspace_id,
      short_id: row.short_id,
      title: row.title,
      mode: safe_to_atom(row.mode),
      status: safe_to_atom(row.status),
      provider: row.provider,
      model: row.model,
      active_task_id: row.active_task_id,
      metadata: JsonField.decode(row.metadata),
      created_at: datetime_to_iso(row.created_at),
      started_at: datetime_to_iso(row.started_at),
      updated_at: datetime_to_iso(row.updated_at)
    }
  end

  @doc "Converts a `Tet.Session` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.Session.t()) :: map()
  def from_core_struct(%Tet.Session{} = core) do
    %{
      id: core.id,
      workspace_id: core.workspace_id,
      short_id: core.short_id,
      title: core.title,
      mode: safe_to_string(core.mode),
      status: safe_to_string(core.status),
      provider: core.provider,
      model: core.model,
      active_task_id: core.active_task_id,
      metadata: JsonField.encode(core.metadata),
      created_at: parse_timestamp(core.created_at),
      started_at: parse_timestamp(core.started_at),
      updated_at: parse_timestamp(core.updated_at)
    }
  end

  # Session core struct stores timestamps as ISO 8601 strings.
  # SQLite stores timestamps as unix integers in milliseconds to preserve
  # sub-second precision across DB round-trips.
  defp datetime_to_iso(nil), do: nil

  defp datetime_to_iso(unix_ms) when is_integer(unix_ms) and unix_ms > 100_000_000_000 do
    unix_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp datetime_to_iso(unix_s) when is_integer(unix_s) do
    unix_s
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(unix) when is_integer(unix), do: unix

  defp parse_timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(str) when is_binary(str), do: String.to_atom(str)

  defp safe_to_string(nil), do: nil
  defp safe_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp safe_to_string(str) when is_binary(str), do: str
end
