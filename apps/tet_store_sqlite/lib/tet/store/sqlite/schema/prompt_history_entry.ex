defmodule Tet.Store.SQLite.Schema.PromptHistoryEntry do
  @moduledoc """
  Ecto schema for the `prompt_history_entries` SQLite table.

  Maps to/from the `Tet.PromptLab.HistoryEntry` core struct. The `request`
  and `result` columns are JSON-encoded BLOBs that round-trip through
  `Tet.PromptLab.Request` and `Tet.PromptLab.Refinement`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "prompt_history_entries" do
    field :version, :string
    field :created_at, :integer
    field :request, :binary
    field :result, :binary
    field :metadata, :binary
  end

  @required ~w(id version created_at request result)a
  @optional ~w(metadata)a

  @doc "Builds a changeset for inserting a prompt history entry."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
  end

  @doc "Converts an Ecto schema row to a `Tet.PromptLab.HistoryEntry` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.PromptLab.HistoryEntry.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.PromptLab.HistoryEntry{
      id: row.id,
      version: row.version,
      created_at: unix_to_iso(row.created_at),
      request: decode_struct(row.request, Tet.PromptLab.Request),
      result: decode_struct(row.result, Tet.PromptLab.Refinement),
      metadata: JsonField.decode(row.metadata)
    }
  end

  @doc "Converts a `Tet.PromptLab.HistoryEntry` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.PromptLab.HistoryEntry.t()) :: map()
  def from_core_struct(%Tet.PromptLab.HistoryEntry{} = core) do
    %{
      id: core.id,
      version: core.version,
      created_at: iso_to_unix(core.created_at),
      request: encode_struct(core.request, Tet.PromptLab.Request),
      result: encode_struct(core.result, Tet.PromptLab.Refinement),
      metadata: JsonField.encode(core.metadata)
    }
  end

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

  defp decode_struct(blob, mod) do
    decoded = JsonField.decode(blob)

    case mod.from_map(decoded) do
      {:ok, struct} -> struct
      _ -> decoded
    end
  end

  defp encode_struct(nil, _mod), do: "{}"

  defp encode_struct(struct, mod) when is_struct(struct) do
    struct |> mod.to_map() |> Jason.encode!()
  end

  defp encode_struct(map, _mod) when is_map(map), do: Jason.encode!(map)
  defp encode_struct(_, _mod), do: "{}"
end
