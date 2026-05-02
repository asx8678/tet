defmodule Tet.Store.SQLite.Schema.LegacyJsonlImport do
  @moduledoc """
  Ecto schema for the `legacy_jsonl_imports` SQLite table.

  Tracking table for legacy JSONL file imports. Uses a composite primary key
  `(source_kind, source_path)` — no single `id` column. There is no
  corresponding core struct; `to_core_struct/1` returns a plain map.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key false

  schema "legacy_jsonl_imports" do
    field :source_kind, :string, primary_key: true
    field :source_path, :string, primary_key: true
    field :source_size, :integer
    field :source_mtime, :integer
    field :sha256, :string
    field :row_count, :integer
    field :imported_at, :integer
  end

  @required ~w(source_kind source_path source_size source_mtime sha256 row_count imported_at)a

  @doc "Builds a changeset for inserting a legacy import tracking record."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_inclusion(:source_kind, ~w(messages events autosaves prompt_history))
    |> validate_length(:sha256, is: 64)
    |> validate_number(:source_size, greater_than_or_equal_to: 0)
    |> validate_number(:row_count, greater_than_or_equal_to: 0)
  end

  @doc "Converts an Ecto schema row to a plain map (no core struct exists)."
  @spec to_core_struct(%__MODULE__{}) :: map()
  def to_core_struct(%__MODULE__{} = row) do
    %{
      source_kind: row.source_kind,
      source_path: row.source_path,
      source_size: row.source_size,
      source_mtime: JsonField.to_datetime(row.source_mtime),
      sha256: row.sha256,
      row_count: row.row_count,
      imported_at: JsonField.to_datetime(row.imported_at)
    }
  end

  @doc "Converts a plain map to changeset-ready attrs."
  @spec from_attrs(map()) :: map()
  def from_attrs(attrs) when is_map(attrs) do
    %{
      source_kind: attrs[:source_kind] || attrs["source_kind"],
      source_path: attrs[:source_path] || attrs["source_path"],
      source_size: attrs[:source_size] || attrs["source_size"],
      source_mtime: resolve_unix(attrs[:source_mtime] || attrs["source_mtime"]),
      sha256: attrs[:sha256] || attrs["sha256"],
      row_count: attrs[:row_count] || attrs["row_count"],
      imported_at: resolve_unix(attrs[:imported_at] || attrs["imported_at"])
    }
  end

  defp resolve_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp resolve_unix(unix) when is_integer(unix), do: unix
  defp resolve_unix(_), do: nil
end
