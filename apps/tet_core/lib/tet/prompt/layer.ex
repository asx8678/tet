defmodule Tet.Prompt.Layer do
  @moduledoc """
  Deterministic prompt layer produced by `Tet.Prompt.build/1`.

  Layers are provider-neutral: each layer has a chat role, raw prompt content,
  normalized metadata, and stable hashes. Debug output uses the hashes and
  redacted metadata instead of dumping raw prompt content.
  """

  @typedoc "Prompt layer bucket. The bucket order is owned by `Tet.Prompt`."
  @type kind ::
          :system_base
          | :project_rules
          | :profile
          | :compaction_metadata
          | :attachment_metadata
          | :session_message

  @type t :: %__MODULE__{
          id: binary(),
          index: non_neg_integer(),
          kind: kind(),
          role: Tet.Message.role(),
          content: binary(),
          metadata: map(),
          content_sha256: binary(),
          hash: binary()
        }

  @enforce_keys [:id, :index, :kind, :role, :content, :metadata, :content_sha256, :hash]
  defstruct [:id, :index, :kind, :role, :content, :metadata, :content_sha256, :hash]
end
