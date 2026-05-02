defmodule Tet.Store.SQLite.Schema.Autosave do
  @moduledoc """
  Ecto schema for the `autosaves` SQLite table.

  Maps to/from the `Tet.Autosave` core struct. Uses `checkpoint_id` as the
  primary key — not the default `id`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:checkpoint_id, :string, autogenerate: false}

  schema "autosaves" do
    field :session_id, :string
    field :saved_at, :integer
    field :messages, :binary
    field :attachments, :binary
    field :prompt_metadata, :binary
    field :prompt_debug, :binary
    field :prompt_debug_text, :string, default: ""
    field :metadata, :binary
  end

  @required ~w(checkpoint_id session_id saved_at)a
  @optional ~w(messages attachments prompt_metadata prompt_debug prompt_debug_text metadata)a

  @doc "Builds a changeset for inserting an autosave checkpoint."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:session_id)
  end

  @doc "Converts an Ecto schema row to a `Tet.Autosave` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.Autosave.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.Autosave{
      checkpoint_id: row.checkpoint_id,
      session_id: row.session_id,
      saved_at: unix_to_iso(row.saved_at),
      messages: decode_messages(row.messages),
      attachments: JsonField.decode_list(row.attachments),
      prompt_metadata: JsonField.decode(row.prompt_metadata),
      prompt_debug: JsonField.decode(row.prompt_debug),
      prompt_debug_text: row.prompt_debug_text || "",
      metadata: JsonField.decode(row.metadata)
    }
  end

  @doc "Converts a `Tet.Autosave` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.Autosave.t()) :: map()
  def from_core_struct(%Tet.Autosave{} = core) do
    %{
      checkpoint_id: core.checkpoint_id,
      session_id: core.session_id,
      saved_at: iso_to_unix(core.saved_at),
      messages: encode_messages(core.messages),
      attachments: JsonField.encode(core.attachments),
      prompt_metadata: JsonField.encode(core.prompt_metadata),
      prompt_debug: JsonField.encode(core.prompt_debug),
      prompt_debug_text: core.prompt_debug_text || "",
      metadata: JsonField.encode(core.metadata)
    }
  end

  # Autosave core struct stores saved_at as an ISO 8601 string.
  defp unix_to_iso(nil), do: nil

  defp unix_to_iso(unix) when is_integer(unix),
    do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp iso_to_unix(nil), do: nil

  defp iso_to_unix(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp iso_to_unix(unix) when is_integer(unix), do: unix

  defp decode_messages(blob) do
    blob
    |> JsonField.decode_list()
    |> Enum.reduce([], fn raw, acc ->
      case Tet.Message.from_map(raw) do
        {:ok, msg} -> [msg | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp encode_messages(messages) when is_list(messages) do
    messages
    |> Enum.map(&Tet.Message.to_map/1)
    |> Jason.encode!()
  end

  defp encode_messages(_), do: "[]"
end
