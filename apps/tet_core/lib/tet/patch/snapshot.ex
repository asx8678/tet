defmodule Tet.Patch.Snapshot do
  @moduledoc """
  A file content snapshot captured before or after a patch operation — BD-0028.

  Snapshots are used for rollback: the pre-apply snapshot stores the file
  content and hash before modification, so the file can be restored if the
  verifier fails. Post-apply snapshots record the final state after a
  successful apply.

  ## Fields

    - `file_path` — workspace-relative file path
    - `content` — the actual file content (binary string)
    - `content_hash` — sha256 hex digest of `content`
    - `captured_at` — `:pre_apply` or `:post_apply`
    - `byte_size` — byte size of the content

  This struct is pure data. Snapshots are created by the runtime layer which
  performs the actual file I/O.
  """

  @capture_types [:pre_apply, :post_apply]

  @enforce_keys [:file_path, :content, :content_hash, :captured_at]
  defstruct [:file_path, :content, :content_hash, :captured_at, byte_size: 0]

  @type capture_type :: :pre_apply | :post_apply

  @type t :: %__MODULE__{
          file_path: String.t(),
          content: String.t(),
          content_hash: String.t(),
          captured_at: capture_type(),
          byte_size: non_neg_integer()
        }

  @doc "Returns valid capture types."
  @spec capture_types() :: [:pre_apply | :post_apply]
  def capture_types, do: @capture_types

  @doc """
  Creates a pre-apply snapshot from file content at a given path.

  Accepts the raw content, computes the sha256 hash, and returns a struct
  with `captured_at: :pre_apply`.
  """
  @spec pre_apply(String.t(), String.t()) :: t()
  def pre_apply(file_path, content) when is_binary(file_path) and is_binary(content) do
    hash = hash_content(content)

    %__MODULE__{
      file_path: file_path,
      content: content,
      content_hash: hash,
      captured_at: :pre_apply,
      byte_size: byte_size(content)
    }
  end

  @doc """
  Creates a post-apply snapshot from file content at a given path.

  Accepts the raw content, computes the sha256 hash, and returns a struct
  with `captured_at: :post_apply`.
  """
  @spec post_apply(String.t(), String.t()) :: t()
  def post_apply(file_path, content) when is_binary(file_path) and is_binary(content) do
    hash = hash_content(content)

    %__MODULE__{
      file_path: file_path,
      content: content,
      content_hash: hash,
      captured_at: :post_apply,
      byte_size: byte_size(content)
    }
  end

  @doc """
  Computes the sha256 hex digest of content.
  """
  @spec hash_content(String.t()) :: String.t()
  def hash_content(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc """
  Converts a snapshot to a JSON-friendly map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    %{
      "file_path" => snapshot.file_path,
      "content_hash" => snapshot.content_hash,
      "captured_at" => Atom.to_string(snapshot.captured_at),
      "byte_size" => snapshot.byte_size,
      "content" => snapshot.content
    }
  end
end
