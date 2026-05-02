defmodule Tet.Store.SQLite.Schema.Message do
  @moduledoc """
  Ecto schema for the `messages` SQLite table.

  Maps to/from the `Tet.Message` core struct. The `content` column is a BLOB
  (may hold plain text or JSON-encoded structured content). The `content_kind`
  and `seq` columns are DB-only — not present on the core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "messages" do
    field :session_id, :string
    field :role, :string
    field :content_kind, :string, default: "text"
    field :content, :binary
    field :metadata, :binary
    field :seq, :integer
    field :created_at, :integer
  end

  @required ~w(id session_id role content seq created_at)a
  @optional ~w(content_kind metadata)a

  @doc "Builds a changeset for inserting a message."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:role, ~w(system user assistant tool))
    |> foreign_key_constraint(:session_id)
    |> unique_constraint([:session_id, :seq])
  end

  @doc "Converts an Ecto schema row to a `Tet.Message` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.Message.t()
  def to_core_struct(%__MODULE__{} = row) do
    created_dt = JsonField.to_datetime(row.created_at)

    %Tet.Message{
      id: row.id,
      session_id: row.session_id,
      role: String.to_existing_atom(row.role),
      content: decode_content(row.content, row.content_kind),
      metadata: JsonField.decode(row.metadata),
      created_at: created_dt,
      timestamp: maybe_iso(created_dt)
    }
  end

  @doc "Converts a `Tet.Message` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.Message.t(), keyword()) :: map()
  def from_core_struct(%Tet.Message{} = core, opts \\ []) do
    %{
      id: core.id,
      session_id: core.session_id,
      role: Atom.to_string(core.role),
      content: encode_content(core.content),
      metadata: JsonField.encode(core.metadata),
      seq: Keyword.get(opts, :seq),
      created_at: resolve_created_at(core)
    }
  end

  defp decode_content(blob, "text"), do: blob
  defp decode_content(blob, _kind), do: blob

  defp encode_content(content) when is_binary(content), do: content
  defp encode_content(content), do: JsonField.encode(content)

  defp resolve_created_at(%Tet.Message{created_at: %DateTime{} = dt}),
    do: DateTime.to_unix(dt)

  defp resolve_created_at(%Tet.Message{timestamp: ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp resolve_created_at(_), do: nil

  defp maybe_iso(nil), do: nil
  defp maybe_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
