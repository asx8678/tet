defmodule Tet.Store.SQLite.Schema.Approval do
  @moduledoc """
  Ecto schema for the `approvals` SQLite table.

  Maps to/from the `Tet.Approval.Approval` core struct.

  Field mapping:
    - DB `tool_run_id`  → core `tool_call_id`
    - DB `reason`       → core `rationale`
    - DB `resolved_at`  → core `approved_at` or `rejected_at` (by status)
    - DB `short_id`, `diff_artifact_id` are DB-only fields
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tet.Store.SQLite.Schema.JsonField

  @primary_key {:id, :string, autogenerate: false}

  schema "approvals" do
    field :session_id, :string
    field :task_id, :string
    field :tool_run_id, :string
    field :short_id, :string
    field :status, :string
    field :reason, :string, default: ""
    field :diff_artifact_id, :string
    field :metadata, :binary
    field :created_at, :integer
    field :updated_at, :integer
    field :resolved_at, :integer
  end

  @required ~w(id session_id tool_run_id status diff_artifact_id created_at updated_at)a
  @optional ~w(task_id short_id reason metadata resolved_at)a

  @doc "Builds a changeset for inserting or updating an approval."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema \\ %__MODULE__{}, attrs) do
    schema
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, ~w(pending approved rejected))
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:tool_run_id)
    |> foreign_key_constraint(:diff_artifact_id)
    |> unique_constraint([:session_id, :short_id])
  end

  @doc "Converts an Ecto schema row to a `Tet.Approval.Approval` core struct."
  @spec to_core_struct(%__MODULE__{}) :: Tet.Approval.Approval.t()
  def to_core_struct(%__MODULE__{} = row) do
    status = String.to_existing_atom(row.status)
    {approved_at, rejected_at} = split_resolved_at(status, row.resolved_at)

    %Tet.Approval.Approval{
      id: row.id,
      tool_call_id: row.tool_run_id,
      status: status,
      rationale: row.reason,
      session_id: row.session_id,
      task_id: row.task_id,
      metadata: JsonField.decode(row.metadata),
      created_at: JsonField.to_datetime(row.created_at),
      approved_at: approved_at,
      rejected_at: rejected_at
    }
  end

  @doc "Converts a `Tet.Approval.Approval` core struct to changeset-ready attrs."
  @spec from_core_struct(Tet.Approval.Approval.t(), keyword()) :: map()
  def from_core_struct(%Tet.Approval.Approval{} = core, opts \\ []) do
    %{
      id: core.id,
      session_id: core.session_id,
      task_id: core.task_id,
      tool_run_id: core.tool_call_id,
      status: Atom.to_string(core.status),
      reason: core.rationale || "",
      diff_artifact_id: Keyword.get(opts, :diff_artifact_id),
      metadata: JsonField.encode(core.metadata),
      created_at: JsonField.from_datetime(core.created_at),
      updated_at: JsonField.from_datetime(core.created_at),
      resolved_at: merge_resolved_at(core)
    }
  end

  defp split_resolved_at(:approved, resolved_at),
    do: {JsonField.to_datetime(resolved_at), nil}

  defp split_resolved_at(:rejected, resolved_at),
    do: {nil, JsonField.to_datetime(resolved_at)}

  defp split_resolved_at(_status, _resolved_at),
    do: {nil, nil}

  defp merge_resolved_at(%{approved_at: at}) when not is_nil(at),
    do: JsonField.from_datetime(at)

  defp merge_resolved_at(%{rejected_at: at}) when not is_nil(at),
    do: JsonField.from_datetime(at)

  defp merge_resolved_at(_), do: nil
end
