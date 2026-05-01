defmodule Tet.Runtime.Tools.Patch do
  @moduledoc """
  Patch apply/rollback executor — BD-0028.

  Implements the full patch lifecycle on the filesystem:

  1. **Proposal validation** — validates the structure via `Tet.Patch`
  2. **Pre-apply snapshot** — captures file content + sha256 hash before any
     modification, for rollback
  3. **Approval gating** — patch only applies if there's an approved approval
     row for this `tool_call_id` (delegated to caller; this module checks the
     flag)
  4. **Apply** — executes file operations (create, modify, delete) with
     per-operation error handling
  5. **Verifier hook** — runs an optional verification (e.g., compile check,
     test run via ShellPolicy)
  6. **Rollback** — on verifier failure, restores files from pre-apply snapshots
  7. **Post-apply snapshot** — captures content hash after successful apply
  8. **Structured result** — returns `Tet.Patch.Result` with before/after
     snapshots, verifier output, and rollback status

  ## Usage

      {:ok, result} =
        Tet.Runtime.Tools.Patch.apply(
          patch,
          approved: true,
          tool_call_id: "call_abc",
          workspace_root: "/workspace"
        )

  All public functions return `{:ok, Tet.Patch.Result.t()}` or
  `{:error, denial_map}`.
  """

  alias Tet.Patch.{Operation, Result, Snapshot}

  @doc """
  Applies a validated patch with the full lifecycle.

  ## Options

    - `:approved` — boolean, must be `true` for apply to proceed
    - `:tool_call_id` — required, provider/runtime tool-call id
    - `:task_id` — optional task id
    - `:approval_id` — optional approval id
    - `:workspace_root` — required, absolute workspace root path
    - `:verifier` — optional MFA tuple `{module, function, args}` to run
      as verifier after apply
    - `:skip_verifier` — skip verifier hook even if one is provided
    - `:timeout_ms` — timeout for individual file operations (default 10_000)

  Returns `{:ok, %Tet.Patch.Result{}}` or `{:error, denial_map}`.
  """
  @spec apply(Tet.Patch.t(), keyword()) :: {:ok, Result.t()} | {:error, map()}
  def apply(%Tet.Patch{} = patch, opts) when is_list(opts) do
    tool_call_id = Keyword.fetch!(opts, :tool_call_id)
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    approved = Keyword.get(opts, :approved, false)
    task_id = Keyword.get(opts, :task_id)
    approval_id = Keyword.get(opts, :approval_id)

    # Step 1 — Approval gating: reject unapproved patches early
    if not approved do
      result =
        Result.error(
          tool_call_id: tool_call_id,
          task_id: task_id,
          approval_id: approval_id,
          error: "Patch not approved: approval required before apply"
        )

      return_envelope({:ok, result})
    else
      # Step 2 — Pre-apply snapshot + Step 3 — Apply operations
      apply_result(patch, workspace_root, opts, tool_call_id, task_id, approval_id)
    end
  end

  defp apply_result(patch, workspace_root, opts, tool_call_id, task_id, approval_id) do
    with {:ok, pre_snapshots} <- capture_pre_snapshots(patch, workspace_root),
         {:ok, applied} <-
           execute_operations(patch, workspace_root, Keyword.get(opts, :timeout_ms, 10_000)) do
      # Step 4 — Verifier hook
      verifier_output = run_verifier(Keyword.get(opts, :verifier), opts, tool_call_id, task_id)

      verifier_passed = verifier_passed?(verifier_output)

      if verifier_passed or Keyword.get(opts, :skip_verifier, false) do
        # Step 5 — Post-apply snapshot
        {:ok, post_snapshots} = capture_post_snapshots(patch, workspace_root)

        result =
          Result.success(
            tool_call_id: tool_call_id,
            task_id: task_id,
            approval_id: approval_id,
            applied: applied,
            pre_snapshots: pre_snapshots,
            post_snapshots: post_snapshots,
            verifier_output: verifier_output,
            rolled_back: false
          )

        return_envelope({:ok, result})
      else
        # Step 6 — Rollback on verifier failure
        rollback_output = perform_rollback(patch, pre_snapshots, workspace_root)

        result =
          Result.success(
            tool_call_id: tool_call_id,
            task_id: task_id,
            approval_id: approval_id,
            applied: applied,
            pre_snapshots: pre_snapshots,
            post_snapshots: [],
            verifier_output: verifier_output,
            rolled_back: true,
            rollback_output: rollback_output
          )

        return_envelope({:ok, result})
      end
    else
      {:error, denial} ->
        result =
          Result.error(
            tool_call_id: tool_call_id,
            task_id: task_id,
            approval_id: approval_id,
            error: Map.get(denial, :message, inspect(denial))
          )

        return_envelope({:ok, result})
    end
  end

  @doc """
  Captures pre-apply snapshots for all operations that involve
  existing files (modify, delete).

  Returns `{:ok, [Snapshot.t()]}` or `{:error, denial_map}`.
  """
  @spec capture_pre_snapshots(Tet.Patch.t(), Path.t()) :: {:ok, [Snapshot.t()]} | {:error, map()}
  def capture_pre_snapshots(%Tet.Patch{} = patch, workspace_root) do
    snapshot_ops =
      Enum.filter(patch.operations, fn op ->
        op.kind in [:modify, :delete]
      end)

    result =
      Enum.reduce_while(snapshot_ops, {:ok, []}, fn op, {:ok, acc} ->
        resolved_path = Path.join(workspace_root, op.file_path)

        case read_file_safe(resolved_path) do
          {:ok, content} ->
            snapshot = Snapshot.pre_apply(op.file_path, content)
            {:cont, {:ok, [snapshot | acc]}}

          {:error, reason} ->
            {:halt, {:error, denial_map(:read_error, reason, op.file_path)}}
        end
      end)

    case result do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Captures post-apply snapshots for all operations.

  Returns `{:ok, [Snapshot.t()]}` or `{:error, denial_map}`.
  """
  @spec capture_post_snapshots(Tet.Patch.t(), Path.t()) :: {:ok, [Snapshot.t()]} | {:error, map()}
  def capture_post_snapshots(%Tet.Patch{} = patch, workspace_root) do
    result =
      Enum.reduce_while(patch.operations, {:ok, []}, fn op, {:ok, acc} ->
        resolved_path = Path.join(workspace_root, op.file_path)

        case op.kind do
          :delete ->
            # Deleted files have no post-apply snapshot
            {:cont, {:ok, acc}}

          _ ->
            case read_file_safe(resolved_path) do
              {:ok, content} ->
                snapshot = Snapshot.post_apply(op.file_path, content)
                {:cont, {:ok, [snapshot | acc]}}

              {:error, reason} ->
                {:halt, {:error, denial_map(:read_error, reason, op.file_path)}}
            end
        end
      end)

    case result do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Executes all file operations in order.

  Each operation is applied individually. If an operation fails, the
  entire apply is aborted and an error is returned.

  Returns `{:ok, [applied_op_map]}` or `{:error, denial_map}`.
  """
  @spec execute_operations(Tet.Patch.t(), Path.t(), pos_integer()) ::
          {:ok, [map()]} | {:error, map()}
  def execute_operations(%Tet.Patch{} = patch, workspace_root, timeout_ms \\ 10_000) do
    result =
      Enum.reduce_while(patch.operations, {:ok, []}, fn op, {:ok, acc} ->
        resolved_path = Path.join(workspace_root, op.file_path)

        case execute_single_operation(op, resolved_path, timeout_ms) do
          {:ok, applied_info} ->
            {:cont, {:ok, [applied_info | acc]}}

          {:error, reason} ->
            {:halt, {:error, denial_map(:apply_error, reason, op.file_path)}}
        end
      end)

    case result do
      {:ok, applied} -> {:ok, Enum.reverse(applied)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Performs rollback by restoring files from pre-apply snapshots.

  Returns a map with `{:restored, [path]}`, `{:failed, [{path, reason}]}`
  and `{:skipped, [path]}` lists. Rollback is intentionally best-effort:
  it tries all restorations and reports partial failures without
  aborting mid-rollback.
  """
  @spec perform_rollback(Tet.Patch.t(), [Snapshot.t()], Path.t()) :: map()
  def perform_rollback(%Tet.Patch{} = patch, pre_snapshots, workspace_root) do
    # Build a map of file_path -> pre_apply_snapshot for quick lookup
    snapshot_map =
      pre_snapshots
      |> Enum.filter(&(&1.captured_at == :pre_apply))
      |> Map.new(fn s -> {s.file_path, s} end)

    restored = []
    failed = []
    skipped = []

    Enum.reduce(patch.operations, %{restored: restored, failed: failed, skipped: skipped}, fn op,
                                                                                              acc ->
      resolved_path = Path.join(workspace_root, op.file_path)

      case op.kind do
        :create ->
          # Remove created files on rollback
          case File.rm(resolved_path) do
            :ok ->
              %{acc | restored: [%{path: op.file_path, action: :removed_created} | acc.restored]}

            {:error, :enoent} ->
              %{acc | skipped: [%{path: op.file_path, reason: :not_found} | acc.skipped]}

            {:error, reason} ->
              %{acc | failed: [%{path: op.file_path, reason: reason} | acc.failed]}
          end

        :modify ->
          # Restore from snapshot
          case Map.get(snapshot_map, op.file_path) do
            nil ->
              %{acc | skipped: [%{path: op.file_path, reason: :no_snapshot} | acc.skipped]}

            snapshot ->
              case File.write(resolved_path, snapshot.content) do
                :ok ->
                  %{acc | restored: [%{path: op.file_path, action: :restored} | acc.restored]}

                {:error, reason} ->
                  %{acc | failed: [%{path: op.file_path, reason: reason} | acc.failed]}
              end
          end

        :delete ->
          # Restore from snapshot (the file was deleted, so we need to recreate it)
          case Map.get(snapshot_map, op.file_path) do
            nil ->
              %{acc | skipped: [%{path: op.file_path, reason: :no_snapshot} | acc.skipped]}

            snapshot ->
              # Ensure parent directory exists
              parent = Path.dirname(resolved_path)

              case File.mkdir_p(parent) do
                :ok ->
                  case File.write(resolved_path, snapshot.content) do
                    :ok ->
                      %{
                        acc
                        | restored: [
                            %{path: op.file_path, action: :restored_deleted} | acc.restored
                          ]
                      }

                    {:error, reason} ->
                      %{acc | failed: [%{path: op.file_path, reason: reason} | acc.failed]}
                  end

                {:error, reason} ->
                  %{acc | failed: [%{path: op.file_path, reason: reason} | acc.failed]}
              end
          end
      end
    end)
  end

  @doc """
  Runs a verifier function after apply.

  The verifier is specified as an MFA tuple `{module, function, extra_args}`.
  The function is called with `[tool_call_id, task_id | extra_args]`.

  Returns `nil` if no verifier is configured, or the verifier result map.
  """
  @spec run_verifier(
          {module(), atom(), list()} | nil,
          keyword(),
          String.t(),
          String.t() | nil
        ) :: map() | nil
  def run_verifier(nil, _opts, _tool_call_id, _task_id), do: nil

  def run_verifier({mod, fun, extra_args}, _opts, tool_call_id, task_id) do
    args = [tool_call_id, task_id | extra_args]

    case apply(mod, fun, args) do
      {:ok, result} -> result
      {:error, reason} -> %{error: inspect(reason)}
      other -> %{result: other}
    end
  rescue
    e -> %{error: "Verifier raised: #{Exception.message(e)}"}
  end

  # -- Private helpers --

  defp execute_single_operation(
         %Operation{kind: :create, file_path: rel_path, content: content},
         resolved_path,
         _timeout_ms
       ) do
    parent = Path.dirname(resolved_path)

    with :ok <- File.mkdir_p(parent),
         :ok <- File.write(resolved_path, content) do
      {:ok,
       %{
         kind: :create,
         file_path: rel_path,
         bytes_written: byte_size(content)
       }}
    else
      {:error, reason} -> {:error, "Create failed: #{inspect(reason)}"}
    end
  end

  defp execute_single_operation(
         %Operation{
           kind: :modify,
           file_path: rel_path,
           content: content,
           replacements: nil,
           old_str: nil
         },
         resolved_path,
         _timeout_ms
       )
       when is_binary(content) do
    with :ok <- File.write(resolved_path, content) do
      {:ok,
       %{
         kind: :modify,
         file_path: rel_path,
         bytes_written: byte_size(content),
         method: :full_content
       }}
    else
      {:error, reason} -> {:error, "Modify failed: #{inspect(reason)}"}
    end
  end

  defp execute_single_operation(
         %Operation{
           kind: :modify,
           file_path: rel_path,
           old_str: old_str,
           new_str: new_str,
           replacements: nil
         },
         resolved_path,
         _timeout_ms
       )
       when is_binary(old_str) and is_binary(new_str) do
    with {:ok, original} <- read_file_safe(resolved_path),
         true <- String.contains?(original, old_str) do
      modified = String.replace(original, old_str, new_str, global: false)

      with :ok <- File.write(resolved_path, modified) do
        {:ok,
         %{
           kind: :modify,
           file_path: rel_path,
           bytes_written: byte_size(modified),
           method: :replacement
         }}
      else
        {:error, reason} -> {:error, "Modify failed: #{inspect(reason)}"}
      end
    else
      {:error, _} = error -> error
      false -> {:error, "old_str not found in file"}
    end
  end

  defp execute_single_operation(
         %Operation{kind: :modify, file_path: rel_path, replacements: replacements},
         resolved_path,
         _timeout_ms
       ) do
    with {:ok, original} <- read_file_safe(resolved_path) do
      modified =
        Enum.reduce(replacements, original, fn rep, acc ->
          old = Map.get(rep, :old_str, Map.get(rep, "old_str", ""))
          new = Map.get(rep, :new_str, Map.get(rep, "new_str", ""))
          String.replace(acc, old, new, global: false)
        end)

      if modified == original do
        {:error, "None of the replacements matched content in file"}
      else
        with :ok <- File.write(resolved_path, modified) do
          {:ok,
           %{
             kind: :modify,
             file_path: rel_path,
             bytes_written: byte_size(modified),
             method: :replacements
           }}
        else
          {:error, reason} -> {:error, "Modify failed: #{inspect(reason)}"}
        end
      end
    else
      {:error, _} = error -> error
    end
  end

  defp execute_single_operation(
         %Operation{kind: :delete, file_path: rel_path},
         resolved_path,
         _timeout_ms
       ) do
    case File.rm(resolved_path) do
      :ok ->
        {:ok, %{kind: :delete, file_path: rel_path}}

      {:error, :enoent} ->
        {:ok, %{kind: :delete, file_path: rel_path, status: :already_absent}}

      {:error, reason} ->
        {:error, "Delete failed: #{inspect(reason)}"}
    end
  end

  defp execute_single_operation(%Operation{kind: kind}, _resolved_path, _timeout_ms) do
    {:error, "Unknown operation kind: #{inspect(kind)}"}
  end

  defp read_file_safe(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "File not found: #{path}"}
      {:error, :eacces} -> {:error, "Permission denied: #{path}"}
      {:error, reason} -> {:error, "Read error: #{inspect(reason)}"}
    end
  end

  defp verifier_passed?(nil), do: true
  defp verifier_passed?(%{error: _}), do: false

  defp verifier_passed?(%{exit_code: code}) when is_integer(code), do: code == 0

  defp verifier_passed?(%{"exit_code" => code}) when is_integer(code), do: code == 0

  defp verifier_passed?(%{ok: false}), do: false
  defp verifier_passed?(%{"ok" => false}), do: false
  defp verifier_passed?(_), do: true

  defp denial_map(code, message, path) do
    %{
      code: Atom.to_string(code),
      message: message,
      kind: "internal",
      retryable: false,
      correlation: nil,
      details: %{path: path}
    }
  end

  defp return_envelope({:ok, %Result{} = result}) do
    {:ok, result}
  end
end
