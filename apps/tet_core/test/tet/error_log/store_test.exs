defmodule Tet.ErrorLog.StoreTest do
  use ExUnit.Case, async: false

  @moduletag :tet_core

  setup do
    # Save original config so we can restore it — no global config leaks.
    original_store = Application.get_env(:tet_core, :store_adapter)
    Application.put_env(:tet_core, :store_adapter, Tet.Store.Memory)

    # Reset the Memory store
    Tet.Store.Memory.reset()

    on_exit(fn ->
      if original_store do
        Application.put_env(:tet_core, :store_adapter, original_store)
      else
        Application.delete_env(:tet_core, :store_adapter)
      end
    end)

    :ok
  end

  # -- log_error --

  describe "log_error/1,2,3" do
    test "log_error/1 with map attrs uses default store" do
      assert {:ok, entry} =
               Tet.ErrorLog.Store.log_error(%{
                 id: "err_001",
                 session_id: "ses_001",
                 kind: :exception,
                 message: "Boom!"
               })

      assert entry.id == "err_001"
      assert entry.status == :open
    end

    test "log_error/2 with attrs and opts" do
      assert {:ok, entry} =
               Tet.ErrorLog.Store.log_error(
                 %{id: "err_002", session_id: "ses_001", kind: :crash, message: "Crash!"},
                 []
               )

      assert entry.id == "err_002"
    end

    test "log_error/3 with store, attrs and opts" do
      assert {:ok, entry} =
               Tet.ErrorLog.Store.log_error(
                 Tet.Store.Memory,
                 %{id: "err_003", session_id: "ses_001", kind: :exception, message: "Test"},
                 []
               )

      assert entry.id == "err_003"
    end

    test "log_error auto-populates created_at when omitted" do
      assert {:ok, entry} =
               Tet.ErrorLog.Store.log_error(%{
                 id: "err_ca",
                 session_id: "ses_001",
                 kind: :exception,
                 message: "No timestamp"
               })

      assert entry.created_at != nil
    end
  end

  # -- list_errors --

  describe "list_errors/1,2,3" do
    test "list_errors/1 returns empty list when no errors" do
      assert {:ok, []} = Tet.ErrorLog.Store.list_errors("ses_empty")
    end

    test "list_errors/1 returns logged errors for session" do
      log_error("ses_list", "err_l1")
      log_error("ses_list", "err_l2")

      assert {:ok, errors} = Tet.ErrorLog.Store.list_errors("ses_list")
      assert length(errors) == 2
    end

    test "list_errors/2 with session and opts" do
      log_error("ses_l2", "err_l3")

      assert {:ok, errors} = Tet.ErrorLog.Store.list_errors("ses_l2", [])
      assert length(errors) == 1
    end
  end

  # -- get_error --

  describe "get_error/1,2,3" do
    test "get_error/1 fetches by id" do
      log_error("ses_get", "err_get_001")

      assert {:ok, entry} = Tet.ErrorLog.Store.get_error("err_get_001")
      assert entry.id == "err_get_001"
    end

    test "get_error/1 returns error for missing id" do
      assert {:error, _} = Tet.ErrorLog.Store.get_error("err_nonexistent")
    end
  end

  # -- resolve_error --

  describe "resolve_error/1,2,3" do
    test "resolve_error/1 resolves an error" do
      log_error("ses_res", "err_res_001")

      assert {:ok, resolved} = Tet.ErrorLog.Store.resolve_error("err_res_001")
      assert resolved.status == :resolved
      assert resolved.resolved_at != nil
    end
  end

  # -- enqueue_repair --

  describe "enqueue_repair/1,2,3" do
    test "enqueue_repair/1 with map attrs" do
      assert {:ok, repair} =
               Tet.ErrorLog.Store.enqueue_repair(%{
                 id: "rep_001",
                 error_log_id: "err_001",
                 strategy: :retry
               })

      assert repair.id == "rep_001"
      assert repair.status == :pending
    end

    test "enqueue_repair/1 sets created_at if not provided" do
      assert {:ok, repair} =
               Tet.ErrorLog.Store.enqueue_repair(%{
                 id: "rep_ca",
                 error_log_id: "err_001",
                 strategy: :retry
               })

      assert repair.created_at != nil
    end
  end

  # -- dequeue_repair --

  describe "dequeue_repair/0,1,2" do
    test "dequeue_repair/0 returns nil when queue empty" do
      assert {:ok, nil} = Tet.ErrorLog.Store.dequeue_repair()
    end

    test "dequeue_repair/0 returns and marks running" do
      Tet.ErrorLog.Store.enqueue_repair(%{
        id: "rep_dq",
        error_log_id: "err_001",
        strategy: :retry
      })

      assert {:ok, repair} = Tet.ErrorLog.Store.dequeue_repair()
      assert repair.id == "rep_dq"
      assert repair.status == :running
    end
  end

  # -- update_repair --

  describe "update_repair/2,3,4" do
    test "update_repair/2 with atom status" do
      enqueue("rep_upd_001", "err_001")

      assert {:ok, updated} =
               Tet.ErrorLog.Store.update_repair("rep_upd_001", %{
                 status: :succeeded,
                 result: %{fixed: true}
               })

      assert updated.status == :succeeded
      assert updated.result == %{fixed: true}
    end

    test "update_repair/2 with string status normalizes to atom" do
      enqueue("rep_str_st", "err_002")

      assert {:ok, updated} =
               Tet.ErrorLog.Store.update_repair("rep_str_st", %{
                 "status" => "succeeded"
               })

      assert updated.status == :succeeded
    end

    test "update_repair/2 returns error tuple on invalid status" do
      enqueue("rep_err_st", "err_004")

      assert {:error, {:invalid_repair_field, :status}} =
               Tet.ErrorLog.Store.update_repair("rep_err_st", %{
                 "status" => "bogus_status"
               })
    end

    test "update_repair/2 returns error for missing repair" do
      assert {:error, _} =
               Tet.ErrorLog.Store.update_repair("rep_nonexistent", %{status: :succeeded})
    end

    test "update_repair/2 protects identity fields from mutation" do
      enqueue("rep_protect", "err_orig")

      assert {:ok, updated} =
               Tet.ErrorLog.Store.update_repair("rep_protect", %{
                 status: :succeeded,
                 id: "hacked_id",
                 error_log_id: "hacked_eid",
                 session_id: "hacked_sid",
                 strategy: :human,
                 created_at: ~U[2099-01-01 00:00:00Z]
               })

      # Mutable field changed
      assert updated.status == :succeeded
      # Identity/correlation fields unchanged
      assert updated.id == "rep_protect"
      assert updated.error_log_id == "err_orig"
      assert updated.session_id == nil
      assert updated.strategy == :retry
      assert updated.created_at != ~U[2099-01-01 00:00:00Z]
    end
  end

  # -- list_repairs --

  describe "list_repairs/0,1,2" do
    test "list_repairs/0 returns all repairs" do
      enqueue("rep_lr1", "err_a")
      enqueue("rep_lr2", "err_b")

      assert {:ok, repairs} = Tet.ErrorLog.Store.list_repairs()
      assert length(repairs) == 2
    end

    test "list_repairs/1 filters by status" do
      enqueue("rep_flt1", "err_c")
      enqueue("rep_flt2", "err_d")

      Tet.ErrorLog.Store.update_repair("rep_flt2", %{status: :succeeded})

      assert {:ok, repairs} = Tet.ErrorLog.Store.list_repairs(status: :succeeded)
      assert length(repairs) == 1
      assert hd(repairs).id == "rep_flt2"
    end
  end

  # -- FIFO ordering --

  describe "FIFO ordering" do
    test "dequeue returns repairs in FIFO order by created_at" do
      early = DateTime.utc_now() |> DateTime.add(-10, :second)
      middle = DateTime.utc_now() |> DateTime.add(-5, :second)
      late = DateTime.utc_now()

      Tet.ErrorLog.Store.enqueue_repair(%{
        id: "rep_fifo_2",
        error_log_id: "err_f1",
        strategy: :retry,
        created_at: middle
      })

      Tet.ErrorLog.Store.enqueue_repair(%{
        id: "rep_fifo_1",
        error_log_id: "err_f2",
        strategy: :retry,
        created_at: early
      })

      Tet.ErrorLog.Store.enqueue_repair(%{
        id: "rep_fifo_3",
        error_log_id: "err_f3",
        strategy: :retry,
        created_at: late
      })

      assert {:ok, r1} = Tet.ErrorLog.Store.dequeue_repair()
      assert r1.id == "rep_fifo_1"

      assert {:ok, r2} = Tet.ErrorLog.Store.dequeue_repair()
      assert r2.id == "rep_fifo_2"

      assert {:ok, r3} = Tet.ErrorLog.Store.dequeue_repair()
      assert r3.id == "rep_fifo_3"
    end

    test "enqueue sets created_at for FIFO ordering without explicit timestamp" do
      Tet.ErrorLog.Store.enqueue_repair(%{
        id: "rep_auto_1",
        error_log_id: "err_auto",
        strategy: :retry
      })

      Tet.ErrorLog.Store.enqueue_repair(%{
        id: "rep_auto_2",
        error_log_id: "err_auto",
        strategy: :retry
      })

      assert {:ok, r1} = Tet.ErrorLog.Store.dequeue_repair()
      assert r1.id == "rep_auto_1"

      assert {:ok, r2} = Tet.ErrorLog.Store.dequeue_repair()
      assert r2.id == "rep_auto_2"
    end
  end

  # -- capture_failure --

  describe "capture_failure/2,3,4" do
    test "creates correlated error log and repair entries" do
      assert {:ok, {error, repair}} =
               Tet.ErrorLog.Store.capture_failure(
                 :exception,
                 %{
                   session_id: "ses_cap",
                   message: "Something went wrong"
                 },
                 strategy: :retry
               )

      assert error.kind == :exception
      assert error.message == "Something went wrong"
      assert error.status == :open
      assert error.session_id == "ses_cap"
      assert error.created_at != nil

      assert repair.error_log_id == error.id
      assert repair.session_id == "ses_cap"
      assert repair.strategy == :retry
      assert repair.status == :pending
      assert repair.created_at != nil
    end

    test "all trigger classes create correlated records" do
      for kind <- Tet.ErrorLog.Store.trigger_classes() do
        Tet.Store.Memory.reset()

        assert {:ok, {error, repair}} =
                 Tet.ErrorLog.Store.capture_failure(
                   kind,
                   %{
                     session_id: "ses_tc_#{kind}",
                     message: "Trigger: #{kind}"
                   },
                   []
                 )

        assert error.kind == kind
        assert repair.error_log_id == error.id
      end
    end

    test "rejects invalid trigger class" do
      assert {:error, {:invalid_trigger_class, :made_up}} =
               Tet.ErrorLog.Store.capture_failure(
                 :made_up,
                 %{session_id: "ses_bad", message: "Bad"},
                 []
               )
    end

    test "defaults strategy by trigger class" do
      defaults = %{
        exception: :retry,
        crash: :retry,
        compile_failure: :patch,
        smoke_failure: :patch,
        remote_failure: :fallback
      }

      for {kind, expected_strategy} <- defaults do
        Tet.Store.Memory.reset()

        assert {:ok, {_error, repair}} =
                 Tet.ErrorLog.Store.capture_failure(
                   kind,
                   %{session_id: "ses_ds_#{kind}", message: "#{kind}"},
                   []
                 )

        assert repair.strategy == expected_strategy
      end
    end

    test "accepts explicit store module" do
      assert {:ok, {error, repair}} =
               Tet.ErrorLog.Store.capture_failure(
                 :exception,
                 Tet.Store.Memory,
                 %{session_id: "ses_explicit", message: "Explicit store"},
                 strategy: :human
               )

      assert error.kind == :exception
      assert repair.strategy == :human
      assert repair.error_log_id == error.id
    end

    test "passes params and metadata to repair" do
      assert {:ok, {_error, repair}} =
               Tet.ErrorLog.Store.capture_failure(
                 :compile_failure,
                 %{session_id: "ses_pm", message: "Compile error"},
                 params: %{file: "lib/bad.ex"},
                 metadata: %{compiler: :elixir}
               )

      assert repair.params == %{file: "lib/bad.ex"}
      assert repair.metadata == %{compiler: :elixir}
    end
  end

  # -- trigger_classes --

  describe "trigger_classes/0" do
    test "returns all 5 trigger classes" do
      classes = Tet.ErrorLog.Store.trigger_classes()

      assert :exception in classes
      assert :crash in classes
      assert :compile_failure in classes
      assert :smoke_failure in classes
      assert :remote_failure in classes
      assert length(classes) == 5
    end
  end

  # -- Helpers --

  defp log_error(session_id, error_id) do
    Tet.ErrorLog.Store.log_error(%{
      id: error_id,
      session_id: session_id,
      kind: :exception,
      message: "Error #{error_id}"
    })
  end

  defp enqueue(repair_id, error_log_id) do
    Tet.ErrorLog.Store.enqueue_repair(%{
      id: repair_id,
      error_log_id: error_log_id,
      strategy: :retry
    })
  end
end
