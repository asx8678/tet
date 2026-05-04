defmodule Tet.Store.SQLite.Schema.WorkflowStep do
  @moduledoc """
  Ecto schema for the `workflow_steps` SQLite table.

  Maps to/from the `Tet.WorkflowStep` core struct.

  Field mapping:
    - DB `failed_at`, `cancelled_at` are DB-only (not on the core struct)
    - Core `session_id`, `created_at` are core-only (not in this table)
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "workflow_steps" do
    field(:workflow_id, :string)
    field(:step_name, :string)
    field(:idempotency_key, :string)
    field(:input, :binary)
    field(:output, :binary)
    field(:error, :binary)
    field(:status, :string)
    field(:attempt, :integer, default: 1)
    field(:metadata, :binary)
    field(:started_at, :integer)
    field(:committed_at, :integer)
    field(:failed_at, :integer)
    field(:cancelled_at, :integer)
  end

  @required ~w(id workflow_id step_name idempotency_key status started_at)a
  @optional ~w(input output error attempt metadata committed_at failed_at cancelled_at)a

  @doc "Builds a changeset for inserting or updating a workflow step."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, ~w(started committed failed cancelled))
    |> validate_length(:idempotency_key, is: 64)
    |> validate_number(:attempt, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:workflow_id)
    |> unique_constraint([:workflow_id, :idempotency_key])
  end

  @doc "Converts an Ecto schema row to a `Tet.WorkflowStep` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.WorkflowStep.t()
  def to_core_struct(%__MODULE__{} = row) do
    %Tet.WorkflowStep{
      id: row.id,
      workflow_id: row.workflow_id,
      step_name: row.step_name,
      idempotency_key: row.idempotency_key,
      input: JsonField.decode_any(row.input),
      output: JsonField.decode_any(row.output),
      error: JsonField.decode_any(row.error),
      status: String.to_atom(row.status),
      attempt: row.attempt,
      metadata: JsonField.decode(row.metadata),
      started_at: JsonField.to_datetime(row.started_at),
      committed_at: JsonField.to_datetime(row.committed_at)
    }
  end

  @doc "Converts a `Tet.WorkflowStep` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.WorkflowStep.t()) :: map()
  def from_core_struct(%Tet.WorkflowStep{} = core) do
    %{
      id: core.id,
      workflow_id: core.workflow_id,
      step_name: core.step_name,
      idempotency_key: core.idempotency_key,
      input: encode_optional(core.input),
      output: encode_optional(core.output),
      error: encode_optional(core.error),
      status: Atom.to_string(core.status),
      attempt: core.attempt,
      metadata: JsonField.encode(core.metadata),
      started_at: JsonField.from_datetime(core.started_at),
      committed_at: JsonField.from_datetime(core.committed_at)
    }
  end

  defp encode_optional(nil), do: nil
  defp encode_optional(value), do: JsonField.encode(value)
end
