defmodule Tet.Approval do
  @moduledoc """
  Approval and diff artifact model facade — BD-0027.

  Provides the public API surface for the approval/artifact/audit story.
  All mutation operations produce one of four linked records:

    1. `Tet.Approval.Approval` — pending/approved/rejected status, approver,
       rationale, and tool_call_id correlation.
    2. `Tet.Approval.DiffArtifact` — old/new content, patch text, file path,
       content hashes, and snapshot references.
    3. `Tet.Approval.Snapshot` — file path, content hash, timestamp, and
       action (taken_before / taken_after).
    4. `Tet.Approval.BlockedAction` — reason from Gate, tool name, args
       summary, and session/task correlation.

  All four structs are linked via correlation IDs (`tool_call_id`, `session_id`,
  `task_id`), ensuring every mutation has a complete approval/artifact/audit
  story.

  This module is pure data and pure functions. It does not dispatch tools,
  touch the filesystem, shell out, persist events, or ask a terminal question.
  """

  alias Tet.Approval.{Approval, BlockedAction, DiffArtifact, Snapshot}

  @doc "Returns all valid approval statuses."
  @spec approval_statuses() :: [Approval.status()]
  def approval_statuses, do: Approval.statuses()

  @doc "Returns all valid snapshot actions."
  @spec snapshot_actions() :: [Snapshot.action()]
  def snapshot_actions, do: Snapshot.actions()

  @doc "Returns known block reasons from Gate decisions."
  @spec known_block_reasons() :: [BlockedAction.reason()]
  def known_block_reasons, do: BlockedAction.known_block_reasons()

  @doc "Delegates to `Approval.new/1`."
  defdelegate new_approval(attrs), to: Approval, as: :new

  @doc "Delegates to `DiffArtifact.new/1`."
  defdelegate new_diff_artifact(attrs), to: DiffArtifact, as: :new

  @doc "Delegates to `Snapshot.new/1`."
  defdelegate new_snapshot(attrs), to: Snapshot, as: :new

  @doc "Delegates to `BlockedAction.new/1`."
  defdelegate new_blocked_action(attrs), to: BlockedAction, as: :new

  @doc "Delegates to `DiffArtifact.from_snapshots/3`."
  defdelegate diff_from_snapshots(snap_before, snap_after, extra), to: DiffArtifact, as: :from_snapshots

  @doc "Delegates to `BlockedAction.from_gate_decision/2`."
  defdelegate blocked_from_gate(attrs, decision), to: BlockedAction, as: :from_gate_decision

  @doc "Delegates to `Snapshot.compute_hash/1`."
  defdelegate compute_content_hash(content), to: Snapshot, as: :compute_hash
end
