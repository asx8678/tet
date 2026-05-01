defmodule Tet.Approval.Snapshot do
  @moduledoc """
  File-content snapshot struct for mutation audit — BD-0027.

  A snapshot captures the content hash (and optionally the full content) of a
  file before or after a mutation. Snapshots are the durable evidence layer
  that links DiffArtifact records to the actual file state at the time of
  mutation.

  ## Action types

  - `:taken_before` — captured before the mutation executes
  - `:taken_after` — captured after the mutation executes

  ## Correlation

  Snapshots are linked to Approval, DiffArtifact, and BlockedAction records
  via shared `tool_call_id`, `session_id`, and `task_id` fields, ensuring
  every mutation has a complete approval/artifact/audit story.

  This module is pure data and pure functions. It does not touch the
  filesystem, shell out, persist events, or ask a terminal question.
  """

  @actions [:taken_before, :taken_after]

  @enforce_keys [:id, :file_path, :content_hash, :action]
  defstruct [
    :id,
    :file_path,
    :content_hash,
    :action,
    :content,
    :timestamp,
    :tool_call_id,
    :session_id,
    :task_id,
    metadata: %{}
  ]

  @type action :: :taken_before | :taken_after
  @type t :: %__MODULE__{
          id: binary(),
          file_path: binary(),
          content_hash: binary(),
          action: action(),
          content: binary() | nil,
          timestamp: DateTime.t() | binary() | nil,
          tool_call_id: binary() | nil,
          session_id: binary() | nil,
          task_id: binary() | nil,
          metadata: map()
        }

  @doc "Returns all valid snapshot actions."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc "True when the snapshot was taken before the mutation."
  @spec before?(t()) :: boolean()
  def before?(%__MODULE__{action: :taken_before}), do: true
  def before?(%__MODULE__{}), do: false

  @doc "True when the snapshot was taken after the mutation."
  @spec after?(t()) :: boolean()
  def after?(%__MODULE__{action: :taken_after}), do: true
  def after?(%__MODULE__{}), do: false

  @doc """
  Builds a validated snapshot from atom or string keyed attributes.

  Required: `:id`, `:file_path`, `:content_hash`, `:action`.
  Optional: `:content`, `:timestamp`, `:tool_call_id`, `:session_id`,
  `:task_id`, `:metadata` (default `%{}`).
  """
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, id} <- fetch_binary(attrs, :id),
         {:ok, file_path} <- fetch_binary(attrs, :file_path),
         {:ok, content_hash} <- fetch_binary(attrs, :content_hash),
         {:ok, action} <- fetch_action(attrs, :action),
         {:ok, content} <- fetch_optional_binary(attrs, :content),
         {:ok, timestamp} <- fetch_optional_timestamp(attrs, :timestamp),
         {:ok, tool_call_id} <- fetch_optional_binary(attrs, :tool_call_id),
         {:ok, session_id} <- fetch_optional_binary(attrs, :session_id),
         {:ok, task_id} <- fetch_optional_binary(attrs, :task_id),
         {:ok, metadata} <- fetch_map(attrs, :metadata, %{}) do
      {:ok,
       %__MODULE__{
         id: id,
         file_path: file_path,
         content_hash: content_hash,
         action: action,
         content: content,
         timestamp: timestamp,
         tool_call_id: tool_call_id,
         session_id: session_id,
         task_id: task_id,
         metadata: metadata
       }}
    end
  end

  @doc "Builds a snapshot or raises."
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    case new(attrs) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> raise ArgumentError, "invalid snapshot: #{inspect(reason)}"
    end
  end

  @doc """
  Computes a SHA-256 content hash for file content.

  Returns a lowercase hex-encoded SHA-256 hash string.
  """
  @spec compute_hash(binary()) :: binary()
  def compute_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Builds a snapshot from file content, computing the hash automatically.

  A convenience builder that calls `compute_hash/1` and delegates to `new/1`.
  """
  @spec from_content(map()) :: {:ok, t()} | {:error, term()}
  def from_content(attrs) when is_map(attrs) do
    case Map.get(attrs, :content, Map.get(attrs, "content")) do
      content when is_binary(content) ->
        attrs = Map.put(attrs, :content_hash, compute_hash(content))
        new(attrs)

      _ ->
        {:error, {:invalid_snapshot_field, :content}}
    end
  end

  @doc "Converts a snapshot to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    %{
      id: snapshot.id,
      file_path: snapshot.file_path,
      content_hash: snapshot.content_hash,
      action: Atom.to_string(snapshot.action),
      content: snapshot.content,
      timestamp: timestamp_value(snapshot.timestamp),
      tool_call_id: snapshot.tool_call_id,
      session_id: snapshot.session_id,
      task_id: snapshot.task_id,
      metadata: snapshot.metadata
    }
  end

  @doc "Converts a decoded map back to a validated snapshot."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  # -- Validators --

  defp fetch_binary(attrs, key) do
    case fetch_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_snapshot_field, key}}
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_snapshot_field, key}}
    end
  end

  defp fetch_action(attrs, key) do
    case fetch_value(attrs, key) do
      action when action in @actions -> {:ok, action}
      action when is_binary(action) -> parse_action(action)
      _ -> {:error, {:invalid_snapshot_field, key}}
    end
  end

  defp parse_action(str) when is_binary(str) do
    case Enum.find(@actions, &(Atom.to_string(&1) == str)) do
      nil -> {:error, {:invalid_snapshot_field, :action}}
      atom -> {:ok, atom}
    end
  end

  defp fetch_optional_timestamp(attrs, key) do
    case fetch_value(attrs, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      %DateTime{} = value -> {:ok, value}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_snapshot_field, key}}
    end
  end

  defp fetch_map(attrs, key, default) do
    case fetch_value(attrs, key, default) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_snapshot_field, key}}
    end
  end

  defp fetch_value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp timestamp_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp_value(value), do: value
end
