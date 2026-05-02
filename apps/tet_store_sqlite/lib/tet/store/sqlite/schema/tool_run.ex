defmodule Tet.Store.SQLite.Schema.ToolRun do
  @moduledoc """
  Ecto schema for the `tool_runs` SQLite table.

  Maps to/from the `Tet.ToolRun` core struct. The `result` column is DB-only —
  not present on the core struct.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "tool_runs" do
    field :session_id, :string
    field :task_id, :string
    field :tool_name, :string
    field :read_or_write, :string
    field :args, :binary
    field :result, :binary
    field :status, :string
    field :block_reason, :string
    field :changed_files, :binary
    field :metadata, :binary
    field :started_at, :integer
    field :finished_at, :integer
  end

  @required ~w(id session_id tool_name read_or_write status)a
  @optional ~w(task_id args result block_reason changed_files metadata started_at finished_at)a

  @doc "Builds a changeset for inserting or updating a tool run."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:read_or_write, ~w(read write))
    |> validate_inclusion(
      :status,
      ~w(proposed blocked waiting_approval running success error)
    )
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:task_id)
  end

  @doc "Converts an Ecto schema row to a `Tet.ToolRun` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.ToolRun.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.ToolRun{
      id: row.id,
      session_id: row.session_id,
      task_id: row.task_id,
      tool_name: row.tool_name,
      read_or_write: String.to_existing_atom(row.read_or_write),
      args: JsonField.decode(row.args),
      status: String.to_existing_atom(row.status),
      block_reason: safe_to_existing_atom(row.block_reason),
      changed_files: JsonField.decode_list(row.changed_files),
      metadata: JsonField.decode(row.metadata),
      started_at: JsonField.to_datetime(row.started_at),
      finished_at: JsonField.to_datetime(row.finished_at)
    }
  end

  @doc "Converts a `Tet.ToolRun` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.ToolRun.t()) :: map()
  def from_core_struct(%Tet.ToolRun{} = core) do
    %{
      id: core.id,
      session_id: core.session_id,
      task_id: core.task_id,
      tool_name: core.tool_name,
      read_or_write: Atom.to_string(core.read_or_write),
      args: JsonField.encode(core.args),
      status: Atom.to_string(core.status),
      block_reason: safe_to_string(core.block_reason),
      changed_files: JsonField.encode(core.changed_files),
      metadata: JsonField.encode(core.metadata),
      started_at: JsonField.from_datetime(core.started_at),
      finished_at: JsonField.from_datetime(core.finished_at)
    }
  end

  defp safe_to_existing_atom(nil), do: nil
  defp safe_to_existing_atom(str) when is_binary(str), do: String.to_existing_atom(str)

  defp safe_to_string(nil), do: nil
  defp safe_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
end
