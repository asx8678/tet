defmodule Tet.Checkpoint do
  @moduledoc """
  Session checkpoint struct for durable state snapshots — BD-0034/BD-0035.

  A checkpoint captures the full runtime state of a session at a point in time,
  enabling crash recovery, resume, and deterministic workflow replay (§12).
  Checkpoints are content-addressable by `sha256` of their serialized state.

  ## Create & restore

      {:ok, cp} = Tet.Checkpoint.create(store, "ses_123", %{foo: "bar"})
      {:ok, snapshot} = Tet.Checkpoint.restore(store, cp.id)

  ## Replay

  See `Tet.Checkpoint.Replay` for replaying workflow steps from a checkpoint.
  """

  alias Tet.Prompt.Canonical

  @enforce_keys [:id, :session_id]
  defstruct [
    :id,
    :session_id,
    :task_id,
    :workflow_id,
    :sha256,
    :state_snapshot,
    :created_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: binary(),
          session_id: binary(),
          task_id: binary() | nil,
          workflow_id: binary() | nil,
          sha256: binary() | nil,
          state_snapshot: map() | nil,
          created_at: binary() | nil,
          metadata: map()
        }

  @doc "Builds a validated checkpoint from atom or string keyed attrs."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, session_id} <- fetch_binary(attrs, :session_id),
         {:ok, task_id} <- fetch_optional_binary(attrs, :task_id),
         {:ok, workflow_id} <- fetch_optional_binary(attrs, :workflow_id),
         {:ok, sha256} <- fetch_optional_binary(attrs, :sha256),
         {:ok, state_snapshot} <- fetch_optional_map(attrs, :state_snapshot),
         {:ok, created_at} <- fetch_optional_binary(attrs, :created_at),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         id: id,
         session_id: session_id,
         task_id: task_id,
         workflow_id: workflow_id,
         sha256: sha256,
         state_snapshot: state_snapshot,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  @doc """
  Creates a checkpoint for the given session, capturing the provided state snapshot.

  The snapshot is hashed (SHA-256) for content-addressability. The checkpoint is
  persisted through the store adapter.

  ## Options

    * `:id` — explicit checkpoint ID (auto-generated if omitted)
    * `:task_id` — optional task correlation
    * `:workflow_id` — optional workflow correlation
    * `:metadata` — additional metadata map (merged into checkpoint metadata)
  """
  @spec create(module(), binary(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def create(store, session_id, state_snapshot, opts \\ []) when is_list(opts) do
    with {:ok, normalized} <- Canonical.normalize(state_snapshot) do
      sha256 = Canonical.hash(normalized)

      id = Keyword.get(opts, :id) || generate_id()
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      metadata = Keyword.get(opts, :metadata, %{})

      attrs = %{
        id: id,
        session_id: session_id,
        task_id: Keyword.get(opts, :task_id),
        workflow_id: Keyword.get(opts, :workflow_id),
        sha256: sha256,
        state_snapshot: state_snapshot,
        created_at: now,
        metadata: metadata
      }

      store.save_checkpoint(attrs, opts)
    end
  end

  @doc """
  Restores a checkpoint by loading it from the store.

  Returns `{:ok, state_snapshot}` on success, or an error tuple if the
  checkpoint is not found.
  """
  @spec restore(module(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore(store, checkpoint_id, opts \\ []) when is_list(opts) do
    with {:ok, checkpoint} <- store.get_checkpoint(checkpoint_id, opts) do
      case checkpoint.state_snapshot do
        nil -> {:error, :empty_checkpoint_snapshot}
        snapshot -> {:ok, snapshot}
      end
    end
  end

  @doc """
  Lists all checkpoints for a session.
  """
  @spec list(module(), binary(), keyword()) :: {:ok, [t()]} | {:error, term()}
  def list(store, session_id, opts \\ []) when is_list(opts) do
    store.list_checkpoints(session_id, opts)
  end

  @doc """
  Deletes a checkpoint by id.
  """
  @spec delete(module(), binary(), keyword()) :: {:ok, :ok} | {:error, term()}
  def delete(store, checkpoint_id, opts \\ []) when is_list(opts) do
    store.delete_checkpoint(checkpoint_id, opts)
  end

  @doc "Converts a checkpoint to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = checkpoint) do
    %{
      id: checkpoint.id,
      session_id: checkpoint.session_id
    }
    |> maybe_put(:task_id, checkpoint.task_id)
    |> maybe_put(:workflow_id, checkpoint.workflow_id)
    |> maybe_put(:sha256, checkpoint.sha256)
    |> maybe_put(:state_snapshot, checkpoint.state_snapshot)
    |> maybe_put(:created_at, checkpoint.created_at)
    |> Map.put(:metadata, checkpoint.metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc "Converts a decoded map back to a validated checkpoint."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- ID generation --

  defp generate_id do
    "cp_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end

  # -- Private helpers --

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_checkpoint_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_checkpoint_field, key}}
    end
  end

  defp fetch_optional_map(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      :null -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_checkpoint_field, key}}
    end
  end

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      nil -> {:ok, default}
      :null -> {:ok, default}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_checkpoint_field, key}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
