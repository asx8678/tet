defmodule StoreContractCase do
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

    quote bind_quoted: [adapter: adapter] do
      @adapter adapter

      # -- Event Log (round-trip) --

      describe "event log persistence" do
        test "round-trips: append_event then get_event", %{opts: opts} do
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
          attrs = %{
            id: "art_rtt_001",
            command: ["echo", "hello"],
            risk: :low,
            exit_code: 0,
            stdout: "hello",
            stderr: "",
            cwd: "/tmp",
            duration_ms: 100,
            tool_call_id: "tc_art_rtt_001",
            task_id: "task_art_session",
            session_id: "ses_artifacts"
          }

          assert {:ok, artifact} = @adapter.create_artifact(attrs, opts)
          assert artifact.id == "art_rtt_001"
          assert artifact.tool_call_id == "tc_art_rtt_001"

          assert {:ok, fetched} = @adapter.get_artifact("art_rtt_001", opts)
          assert fetched.id == "art_rtt_001"
          assert fetched.command == ["echo", "hello"]

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
          attrs = %{
            id: "cp_rtt_001",
            session_id: "ses_cp",
            sha256: "abc123",
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
          attrs = %{
            id: "step_rtt_001",
            workflow_id: "wf_001",
            session_id: "ses_steps",
            name: "research",
            idempotency_key: "ik_001",
            status: :pending
          }

          assert {:ok, step} = @adapter.append_step(attrs, opts)
          assert step.id == "step_rtt_001"
          assert step.workflow_id == "wf_001"
          assert step.session_id == "ses_steps"

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
      end

      # -- Repair Queue (round-trip) --

      describe "repair queue persistence" do
        test "full repair lifecycle with round-trip", %{opts: opts} do
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
      end
    end
  end
end
