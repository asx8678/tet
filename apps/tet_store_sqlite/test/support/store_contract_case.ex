defmodule Tet.Store.SQLite.StoreContractCase do
  @moduledoc """
  Shared contract tests for `Tet.Store` adapters (Memory and SQLite).

  Every adapter must pass these round-trip persistence assertions so that
  runtime callers can rely on consistent behaviour regardless of the backing
  store.

  Usage:

      defmodule MyStoreContractTest do
        use ExUnit.Case

        setup do
          # ... adapter-specific setup returning {:ok, opts: keyword()}
        end

        use StoreContractCase, adapter: MyStoreAdapter
      end

  The host module must define its own `setup` block that provides
  `{:ok, opts: keyword()}`. The shared tests use `%{opts: opts}` from context.
  """

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    quote do
      @adapter unquote(adapter)

      # 64-char lowercase hex strings satisfying DB CHECK constraints
      @sha256_a "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb"
      @idem_key_a "aaaa0001bbbb0002cccc0003dddd0004eeee0005ffff00060000aaaa0000bbbb"
      @idem_key_b "aaaa0002bbbb0003cccc0004dddd0005eeee0006ffff00070000aaaa0001bbbb"

      # -- Helper: create FK parent chain (workspace → session) --

      defp create_workspace_session!(ws_id, ses_id) do
        {:ok, _ws} =
          @adapter.create_workspace(%{
            id: ws_id,
            name: "test-workspace",
            root_path: "/tmp/test-#{ws_id}",
            tet_dir_path: "/tmp/test-#{ws_id}/.tet",
            trust_state: :trusted
          })

        {:ok, _ses} =
          @adapter.create_session(%{
            id: ses_id,
            workspace_id: ws_id,
            short_id: String.slice(ses_id, 0, 8),
            mode: :chat,
            status: :idle
          })

        :ok
      end

      # -- Helper: create FK chain for workflow steps (workspace → session → workflow) --

      defp create_workflow_chain!(ws_id, ses_id, wf_id) do
        create_workspace_session!(ws_id, ses_id)

        {:ok, _wf} =
          @adapter.create_workflow(%{
            id: wf_id,
            session_id: ses_id,
            status: :running
          })

        :ok
      end

      # -- Event Log (round-trip) --

      describe "event log persistence" do
        test "round-trips: append_event then get_event", %{opts: opts} do
          create_workspace_session!("ws_evt_rtt", "ses_rtt")

          attrs = %{
            id: "evt_rtt_001",
            type: :"session.created",
            session_id: "ses_rtt",
            payload: %{message: "hello"},
            metadata: %{},
            created_at: "2025-01-01T00:00:00Z"
          }

          assert {:ok, event} = @adapter.append_event(attrs, opts)
          assert event.id == "evt_rtt_001"
          assert event.type == :"session.created"
          assert event.session_id == "ses_rtt"

          assert {:ok, fetched} = @adapter.get_event("evt_rtt_001", opts)
          assert fetched.id == "evt_rtt_001"
          assert fetched.type == :"session.created"
        end

        test "returns error for non-existent event", %{opts: opts} do
          assert {:error, :event_not_found} = @adapter.get_event("nonexistent_evt", opts)
        end

        test "list_events filters by session", %{opts: opts} do
          create_workspace_session!("ws_evt_list", "ses_list")
          create_workspace_session!("ws_evt_other", "ses_other")

          @adapter.append_event(
            %{
              id: "evt_list_a",
              type: :"session.created",
              session_id: "ses_list",
              payload: %{},
              metadata: %{}
            },
            opts
          )

          @adapter.append_event(
            %{
              id: "evt_list_b",
              type: :"provider.started",
              session_id: "ses_list",
              payload: %{},
              metadata: %{}
            },
            opts
          )

          @adapter.append_event(
            %{
              id: "evt_list_c",
              type: :"session.created",
              session_id: "ses_other",
              payload: %{},
              metadata: %{}
            },
            opts
          )

          assert {:ok, events} = @adapter.list_events("ses_list", opts)
          ids = Enum.map(events, & &1.id)
          assert "evt_list_a" in ids
          assert "evt_list_b" in ids
          refute "evt_list_c" in ids
        end
      end

      # -- Artifacts (round-trip) --

      describe "artifact persistence" do
        test "round-trips: create_artifact then get_artifact and list_artifacts", %{opts: opts} do
          create_workspace_session!("ws_art_rtt", "ses_artifacts")

          attrs = %{
            id: "art_rtt_001",
            workspace_id: "ws_art_rtt",
            session_id: "ses_artifacts",
            kind: "stdout",
            sha256: @sha256_a,
            size_bytes: 5,
            inline_blob: "hello",
            created_at: System.system_time(:second)
          }

          assert {:ok, artifact} = @adapter.create_artifact(attrs, opts)
          assert artifact.id == "art_rtt_001"

          assert {:ok, fetched} = @adapter.get_artifact("art_rtt_001", opts)
          assert fetched.id == "art_rtt_001"
          assert fetched.kind == :stdout

          assert {:ok, artifacts} = @adapter.list_artifacts("ses_artifacts", opts)
          assert length(artifacts) >= 1
        end

        test "returns error for non-existent artifact", %{opts: opts} do
          assert {:error, :artifact_not_found} = @adapter.get_artifact("missing_art", opts)
        end
      end

      # -- Checkpoints (round-trip) --

      describe "checkpoint persistence" do
        test "full checkpoint lifecycle", %{opts: opts} do
          create_workspace_session!("ws_cp_rtt", "ses_cp")

          attrs = %{
            id: "cp_rtt_001",
            session_id: "ses_cp",
            sha256: @sha256_a,
            created_at: "2025-01-01T00:00:00Z"
          }

          assert {:ok, checkpoint} = @adapter.save_checkpoint(attrs, opts)
          assert checkpoint.id == "cp_rtt_001"
          assert checkpoint.session_id == "ses_cp"

          assert {:ok, fetched} = @adapter.get_checkpoint("cp_rtt_001", opts)
          assert fetched.id == "cp_rtt_001"

          assert {:ok, checkpoints} = @adapter.list_checkpoints("ses_cp", opts)
          assert length(checkpoints) >= 1

          assert {:ok, :ok} = @adapter.delete_checkpoint("cp_rtt_001", opts)
          assert {:error, :checkpoint_not_found} = @adapter.get_checkpoint("cp_rtt_001", opts)
        end

        test "returns error for non-existent checkpoint", %{opts: opts} do
          assert {:error, :checkpoint_not_found} = @adapter.get_checkpoint("missing_cp", opts)
        end
      end

      # -- Workflow Steps (round-trip) --

      describe "workflow step persistence" do
        test "round-trips: append_step then get_steps by session", %{opts: opts} do
          create_workflow_chain!("ws_step_rtt", "ses_steps", "wf_001")

          attrs = %{
            id: "step_rtt_001",
            workflow_id: "wf_001",
            session_id: "ses_steps",
            name: "research",
            idempotency_key: @idem_key_a,
            status: :started,
            attempt: 1
          }

          assert {:ok, step} = @adapter.append_step(attrs, opts)
          assert step.id == "step_rtt_001"
          assert step.workflow_id == "wf_001"

          assert {:ok, steps} = @adapter.get_steps("ses_steps", opts)
          step_ids = Enum.map(steps, & &1.id)
          assert "step_rtt_001" in step_ids

          # Steps from a different session should not appear
          assert {:ok, other_steps} = @adapter.get_steps("ses_other", opts)
          refute "step_rtt_001" in Enum.map(other_steps, & &1.id)
        end
      end

      # -- Error Log (round-trip) --

      describe "error log persistence" do
        test "full error lifecycle with round-trip", %{opts: opts} do
          create_workspace_session!("ws_err_rtt", "ses_errors")

          attrs = %{
            id: "err_rtt_001",
            session_id: "ses_errors",
            kind: :provider_error,
            message: "API rate limit exceeded",
            context: %{status: 429}
          }

          assert {:ok, error_entry} = @adapter.log_error(attrs, opts)
          assert error_entry.id == "err_rtt_001"
          assert error_entry.status == :open

          assert {:ok, fetched} = @adapter.get_error("err_rtt_001", opts)
          assert fetched.id == "err_rtt_001"
          assert fetched.kind == :provider_error

          assert {:ok, errors} = @adapter.list_errors("ses_errors", opts)
          assert length(errors) >= 1

          assert {:ok, resolved} = @adapter.resolve_error("err_rtt_001", opts)
          assert resolved.status == :resolved
          assert resolved.resolved_at != nil

          # Re-fetch confirms persistence of resolution
          assert {:ok, confirmed} = @adapter.get_error("err_rtt_001", opts)
          assert confirmed.status == :resolved
        end

        test "returns error for non-existent error", %{opts: opts} do
          assert {:error, :error_not_found} = @adapter.get_error("missing_err", opts)
        end

        test "returns error when resolving non-existent error", %{opts: opts} do
          assert {:error, :error_not_found} = @adapter.resolve_error("missing_err", opts)
        end

        test "auto-populates created_at when omitted", %{opts: opts} do
          create_workspace_session!("ws_err_auto", "ses_auto_ca")

          attrs = %{
            id: "err_auto_ca",
            session_id: "ses_auto_ca",
            kind: :exception,
            message: "No timestamp"
          }

          assert {:ok, error_entry} = @adapter.log_error(attrs, opts)
          assert error_entry.created_at != nil
        end
      end

      # -- Repair Queue (round-trip) --

      describe "repair queue persistence" do
        test "full repair lifecycle with round-trip", %{opts: opts} do
          create_workspace_session!("ws_rep_rtt", "ses_repairs")

          # Create the error_log entry first (FK parent for repair)
          assert {:ok, _error} =
                   @adapter.log_error(
                     %{
                       id: "err_rtt_001",
                       session_id: "ses_repairs",
                       kind: :provider_error,
                       message: "test error for repair"
                     },
                     opts
                   )

          attrs = %{
            id: "rep_rtt_001",
            error_log_id: "err_rtt_001",
            session_id: "ses_repairs",
            strategy: :retry
          }

          assert {:ok, repair} = @adapter.enqueue_repair(attrs, opts)
          assert repair.id == "rep_rtt_001"
          assert repair.status == :pending

          # Dequeue picks up the pending repair
          assert {:ok, dequeued} = @adapter.dequeue_repair(opts)
          assert dequeued.id == "rep_rtt_001"
          assert dequeued.status == :running

          # Dequeue again returns nil (no more pending)
          assert {:ok, nil} = @adapter.dequeue_repair(opts)

          # Update the repair to succeeded
          assert {:ok, succeeded} =
                   @adapter.update_repair(
                     "rep_rtt_001",
                     %{status: :succeeded, result: %{success: true}},
                     opts
                   )

          assert succeeded.status == :succeeded

          # List repairs
          assert {:ok, repairs} = @adapter.list_repairs(opts)
          assert length(repairs) >= 1

          # List by session
          filtered_opts = Keyword.merge(opts, session_id: "ses_repairs")
          assert {:ok, session_repairs} = @adapter.list_repairs(filtered_opts)
          assert length(session_repairs) >= 1

          # List by status
          filtered_opts = Keyword.merge(opts, status: :succeeded)
          assert {:ok, succeeded_repairs} = @adapter.list_repairs(filtered_opts)
          assert length(succeeded_repairs) >= 1
        end

        test "returns error for non-existent repair update", %{opts: opts} do
          assert {:error, :repair_not_found} =
                   @adapter.update_repair("missing_rep", %{status: :succeeded}, opts)
        end

        test "update_repair protects identity fields from mutation", %{opts: opts} do
          create_workspace_session!("ws_rep_protect", "ses_protect")

          # Create the error_log entry first (FK parent for repair)
          assert {:ok, _error} =
                   @adapter.log_error(
                     %{
                       id: "err_protect",
                       session_id: "ses_protect",
                       kind: :provider_error,
                       message: "test"
                     },
                     opts
                   )

          attrs = %{
            id: "rep_protect_001",
            error_log_id: "err_protect",
            session_id: "ses_protect",
            strategy: :retry
          }

          assert {:ok, repair} = @adapter.enqueue_repair(attrs, opts)
          original_created_at = repair.created_at

          # Try to mutate identity/correlation fields
          assert {:ok, updated} =
                   @adapter.update_repair(
                     "rep_protect_001",
                     %{
                       status: :succeeded,
                       id: "hacked_id",
                       error_log_id: "hacked_eid",
                       session_id: "hacked_sid",
                       strategy: :human,
                       created_at: ~U[2099-01-01 00:00:00Z]
                     },
                     opts
                   )

          # Mutable field changed
          assert updated.status == :succeeded
          # Identity/correlation fields unchanged
          assert updated.id == "rep_protect_001"
          assert updated.error_log_id == "err_protect"
          assert updated.session_id == "ses_protect"
          assert updated.strategy == :retry
          assert updated.created_at == original_created_at
        end

        test "update_repair returns error tuple for invalid status", %{opts: opts} do
          create_workspace_session!("ws_rep_inv", "ses_inv")

          # Create the error_log FK entry
          assert {:ok, _} =
                   @adapter.log_error(
                     %{id: "err_inv", session_id: "ses_inv", kind: :exception, message: "inv"},
                     opts
                   )

          attrs = %{
            id: "rep_inv_st",
            error_log_id: "err_inv",
            session_id: "ses_inv",
            strategy: :retry
          }

          assert {:ok, _repair} = @adapter.enqueue_repair(attrs, opts)

          assert {:error, {:invalid_repair_field, :status}} =
                   @adapter.update_repair("rep_inv_st", %{"status" => "bogus"}, opts)
        end

        test "enqueue_repair auto-populates created_at when omitted", %{opts: opts} do
          create_workspace_session!("ws_rep_auto", "ses_auto")

          attrs = %{
            id: "rep_auto_ca",
            error_log_id: "err_auto",
            strategy: :retry
          }

          # First create the error_log FK entry
          assert {:ok, _} =
                   @adapter.log_error(
                     %{id: "err_auto", session_id: "ses_auto", kind: :exception, message: "auto"},
                     opts
                   )

          assert {:ok, repair} = @adapter.enqueue_repair(attrs, opts)
          assert repair.created_at != nil
        end

        test "dequeue returns repairs in FIFO order by created_at", %{opts: opts} do
          create_workspace_session!("ws_rep_fifo", "ses_fifo")

          # Create the error_log FK entry
          assert {:ok, _} =
                   @adapter.log_error(
                     %{id: "err_fifo", session_id: "ses_fifo", kind: :exception, message: "fifo"},
                     opts
                   )

          early = DateTime.utc_now() |> DateTime.add(-10, :second)
          middle = DateTime.utc_now() |> DateTime.add(-5, :second)
          late = DateTime.utc_now()

          @adapter.enqueue_repair(
            %{id: "rep_fifo_m", error_log_id: "err_fifo", strategy: :retry, created_at: middle},
            opts
          )

          @adapter.enqueue_repair(
            %{id: "rep_fifo_e", error_log_id: "err_fifo", strategy: :retry, created_at: early},
            opts
          )

          @adapter.enqueue_repair(
            %{id: "rep_fifo_l", error_log_id: "err_fifo", strategy: :retry, created_at: late},
            opts
          )

          assert {:ok, r1} = @adapter.dequeue_repair(opts)
          assert r1.id == "rep_fifo_e"

          assert {:ok, r2} = @adapter.dequeue_repair(opts)
          assert r2.id == "rep_fifo_m"

          assert {:ok, r3} = @adapter.dequeue_repair(opts)
          assert r3.id == "rep_fifo_l"
        end
      end

      # -- Event Ordering (monotonic seq) --

      describe "event ordering" do
        test "events are returned in monotonic seq order", %{opts: opts} do
          create_workspace_session!("ws_evt_ord", "ses_ord")

          for i <- 1..5 do
            @adapter.append_event(
              %{
                id: "evt_ord_#{i}",
                type: :"provider.started",
                session_id: "ses_ord",
                payload: %{step: i},
                metadata: %{}
              },
              opts
            )
          end

          assert {:ok, events} = @adapter.list_events("ses_ord", opts)
          seqs = Enum.map(events, & &1.seq)
          assert seqs == Enum.sort(seqs), "Events must be in monotonic order"
          assert length(seqs) == 5
        end
      end
    end
  end
end
