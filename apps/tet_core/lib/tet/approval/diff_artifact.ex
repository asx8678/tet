defmodule Tet.Approval.DiffArtifact do
  @moduledoc """
  Diff artifact struct for mutation audit — BD-0027.

  A diff artifact captures the before/after state of a file mutation,
  including old and new content, a unified-diff patch, content hashes,
  and references to the Snapshot records taken before and after the mutation.

  ## Correlation

  DiffArtifact records are linked to Approval, Snapshot, and BlockedAction
  records via shared `tool_call_id`, `session_id`, and `task_id` fields,
  ensuring every mutation has a complete approval/artifact/audit story.

  This module is pure data and pure functions. It does not touch the
  filesystem, shell out, persist events, or ask a terminal question.
  """

  alias Tet.Approval.Snapshot

  @enforce_keys [:id, :tool_call_id, :file_path, :content_hash_before, :content_hash_after]
  defstruct [
    :id,
    :tool_call_id,
    :file_path,
    :content_hash_before,
    :content_hash_after,
    :old_content,
    :new_content,
    :patch_text,
    :snapshot_before_id,
    :snapshot_after_id,
    :session_id,
    :task_id,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: binary(),
          tool_call_id: binary(),
          file_path: binary(),
          content_hash_before: binary(),
          content_hash_after: binary(),
          old_content: binary() | nil,
          new_content: binary() | nil,
          patch_text: binary() | nil,
          snapshot_before_id: binary() | nil,
          snapshot_after_id: binary() | nil,
          session_id: binary() | nil,
          task_id: binary() | nil,
          metadata: map()
        }

  # Fields that are safe to accept in the extra map (non-derived, user-supplied).
  @extra_whitelist [:id, :patch_text, :metadata]

  @doc """
  Builds a validated diff artifact from atom or string keyed attributes.

  Required: `:id`, `:tool_call_id`, `:file_path`, `:content_hash_before`,
  `:content_hash_after`.
  Optional: `:old_content`, `:new_content`, `:patch_text`,
  `:snapshot_before_id`, `:snapshot_after_id`, `:session_id`, `:task_id`,
  `:metadata` (default `%{}`).
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, tool_call_id} <- fetch_binary(attrs, :tool_call_id),
         {:ok, file_path} <- fetch_binary(attrs, :file_path),
         {:ok, content_hash_before} <- fetch_binary(attrs, :content_hash_before),
         {:ok, content_hash_after} <- fetch_binary(attrs, :content_hash_after),
         {:ok, old_content} <- fetch_optional_binary(attrs, :old_content),
         {:ok, new_content} <- fetch_optional_binary(attrs, :new_content),
         {:ok, patch_text} <- fetch_optional_binary(attrs, :patch_text),
         {:ok, snapshot_before_id} <- fetch_optional_binary(attrs, :snapshot_before_id),
         {:ok, snapshot_after_id} <- fetch_optional_binary(attrs, :snapshot_after_id),
         {:ok, session_id} <- fetch_optional_binary(attrs, :session_id),
         {:ok, task_id} <- fetch_optional_binary(attrs, :task_id),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}),
         :ok <- validate_hash_consistency(old_content, content_hash_before, :content_hash_before),
         :ok <- validate_hash_consistency(new_content, content_hash_after, :content_hash_after) do
      {:ok,
       %__MODULE__{
         id: id,
         tool_call_id: tool_call_id,
         file_path: file_path,
         content_hash_before: content_hash_before,
         content_hash_after: content_hash_after,
         old_content: old_content,
         new_content: new_content,
         patch_text: patch_text,
         snapshot_before_id: snapshot_before_id,
         snapshot_after_id: snapshot_after_id,
         session_id: session_id,
         task_id: task_id,
         metadata: metadata
       }}
    end
  end

  @doc "Builds a diff artifact or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, artifact} -> artifact
      {:error, reason} -> raise ArgumentError, "invalid diff artifact: #{inspect(reason)}"
    end
  end

  @doc """
  Builds a diff artifact from two Snapshot records and optional patch text.

  Validates:
  - `snap_before.action == :taken_before`
  - `snap_after.action == :taken_after`
  - matching `tool_call_id`, `session_id`, `task_id` between snapshots
  - `extra` keys are whitelisted to non-derived fields only

  Returns `{:error, reason}` for any validation violation.
  """
  @spec from_snapshots(Snapshot.t(), Snapshot.t(), map()) :: {:ok, t()} | {:error, term()}
  def from_snapshots(%Snapshot{} = snap_before, %Snapshot{} = snap_after, extra \\ %{})
      when is_map(extra) do
    with :ok <- validate_snapshot_actions(snap_before, snap_after),
         :ok <- validate_snapshot_correlation(snap_before, snap_after),
         :ok <- validate_file_path_match(snap_before, snap_after),
         :ok <- validate_extra_whitelist(extra) do
      attrs =
        %{
          file_path: snap_before.file_path,
          content_hash_before: snap_before.content_hash,
          content_hash_after: snap_after.content_hash,
          snapshot_before_id: snap_before.id,
          snapshot_after_id: snap_after.id,
          tool_call_id: snap_before.tool_call_id || snap_after.tool_call_id,
          session_id: snap_before.session_id || snap_after.session_id,
          task_id: snap_before.task_id || snap_after.task_id
        }
        |> maybe_put_content(snap_before.content, :old_content)
        |> maybe_put_content(snap_after.content, :new_content)
        |> Map.merge(Map.take(extra, @extra_whitelist))

      new(attrs)
    end
  end

  @doc "Converts a diff artifact to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = artifact) do
    %{
      id: artifact.id,
      tool_call_id: artifact.tool_call_id,
      file_path: artifact.file_path,
      content_hash_before: artifact.content_hash_before,
      content_hash_after: artifact.content_hash_after,
      old_content: artifact.old_content,
      new_content: artifact.new_content,
      patch_text: artifact.patch_text,
      snapshot_before_id: artifact.snapshot_before_id,
      snapshot_after_id: artifact.snapshot_after_id,
      session_id: artifact.session_id,
      task_id: artifact.task_id,
      metadata: artifact.metadata
    }
  end

  @doc "Converts a decoded map back to a validated diff artifact."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Validators --

  defp validate_snapshot_actions(%Snapshot{action: :taken_before}, %Snapshot{action: :taken_after}),
       do: :ok

  defp validate_snapshot_actions(%Snapshot{action: before_action}, %Snapshot{action: after_action}),
       do: {:error, {:invalid_snapshot_actions, before_action, after_action}}

  defp validate_snapshot_correlation(snap_before, snap_after) do
    errors =
      []
      |> check_correlation(:tool_call_id, snap_before, snap_after)
      |> check_correlation(:session_id, snap_before, snap_after)
      |> check_correlation(:task_id, snap_before, snap_after)

    if errors == [], do: :ok, else: {:error, {:snapshot_correlation_mismatch, errors}}
  end

  defp check_correlation(errors, field, snap_before, snap_after) do
    before_val = Map.get(snap_before, field)
    after_val = Map.get(snap_after, field)

    if before_val != nil and after_val != nil and before_val != after_val do
      [{field, before_val, after_val} | errors]
    else
      errors
    end
  end

  defp validate_file_path_match(snap_before, snap_after) do
    if snap_before.file_path == snap_after.file_path do
      :ok
    else
      {:error, {:snapshot_file_path_mismatch, snap_before.file_path, snap_after.file_path}}
    end
  end

  defp validate_extra_whitelist(extra) do
    invalid = Map.keys(extra) -- @extra_whitelist

    if invalid == [] do
      :ok
    else
      {:error, {:invalid_extra_fields, invalid}}
    end
  end

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_diff_artifact_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_diff_artifact_field, key}}
    end
  end

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_diff_artifact_field, key}}
    end
  end

  # When content is provided, its computed hash must match the declared hash.
  defp validate_hash_consistency(nil, _hash, _key), do: :ok

  defp validate_hash_consistency(content, declared_hash, key) when is_binary(content) do
    computed = Snapshot.compute_hash(content)

    if computed == declared_hash do
      :ok
    else
      {:error, {:hash_mismatch, key, computed, declared_hash}}
    end
  end

  defp maybe_put_content(attrs, nil, _key), do: attrs

  defp maybe_put_content(attrs, content, key) when is_binary(content),
    do: Map.put(attrs, key, content)

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
