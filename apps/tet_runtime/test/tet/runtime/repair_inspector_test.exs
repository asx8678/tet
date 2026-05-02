defmodule Tet.Runtime.RepairInspectorTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.RepairInspector
  alias Tet.HookManager
  alias Tet.HookManager.Hook

  # ── Test store that returns controlled data ─────────────────────────────

  defmodule TestStore do
    @behaviour Tet.Store

    @doc false
    def start_link(_opts), do: {:ok, self()}

    @impl true
    def boundary, do: %{application: :test, status: :ok}

    @impl true
    def health(_opts), do: {:ok, %{status: :ok, adapter: __MODULE__}}

    @impl true
    def transaction(fun), do: fun.()

    # Configured via Agent for test control
    @doc false
    def configure(errors, repairs) do
      Agent.update(__MODULE__, fn state ->
        %{state | errors: errors, repairs: repairs, fail_errors: nil, fail_repairs: nil}
      end)
    end

    @doc false
    def fail_errors(reason) do
      Agent.update(__MODULE__, fn state -> %{state | fail_errors: reason} end)
    end

    @doc false
    def fail_repairs(reason) do
      Agent.update(__MODULE__, fn state -> %{state | fail_repairs: reason} end)
    end

    @doc false
    def start_agent do
      case Agent.start_link(
             fn -> %{errors: [], repairs: [], fail_errors: nil, fail_repairs: nil} end,
             name: __MODULE__
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    @impl true
    def list_errors(session_id, _opts) do
      state = Agent.get(__MODULE__, fn state -> state end)

      if fail = Map.get(state, :fail_errors) do
        {:error, fail}
      else
        {:ok, Enum.filter(Map.get(state, :errors, []), &(&1.session_id == session_id))}
      end
    end

    @impl true
    def list_repairs(_opts) do
      state = Agent.get(__MODULE__, fn state -> state end)

      if fail = Map.get(state, :fail_repairs) do
        {:error, fail}
      else
        {:ok, Map.get(state, :repairs, [])}
      end
    end

    # Stub remaining callbacks as needed by the Store behaviour
    @impl true
    def create_workspace(_attrs), do: {:ok, %{}}
    @impl true
    def get_workspace(_id), do: {:error, :not_found}
    @impl true
    def set_trust(_id, _state), do: {:ok, %{}}
    @impl true
    def create_session(_attrs), do: {:ok, %{}}
    @impl true
    def update_session(_id, _attrs), do: {:ok, %{}}
    @impl true
    def get_session(_id), do: {:error, :not_found}
    @impl true
    def list_sessions(_wid), do: {:ok, []}
    @impl true
    def create_task(_attrs), do: {:ok, %{}}
    @impl true
    def append_message(_attrs), do: {:ok, %{}}
    @impl true
    def record_tool_run(_attrs), do: {:ok, %{}}
    @impl true
    def update_tool_run(_id, _attrs), do: {:ok, %{}}
    @impl true
    def create_approval(_attrs), do: {:ok, %{}}
    @impl true
    def resolve_approval(_id, _res, _attrs), do: {:ok, %{}}
    @impl true
    def get_approval(_id), do: {:error, :not_found}
    @impl true
    def list_approvals(_sid, _opts), do: {:ok, []}
    @impl true
    def create_artifact(_attrs, _opts), do: {:ok, %{}}
    @impl true
    def get_artifact(_id, _opts), do: {:error, :not_found}
    @impl true
    def emit_event(_attrs), do: {:ok, %{}}
    @impl true
    def list_events(_sid, _opts), do: {:ok, []}
    @impl true
    def create_workflow(_attrs), do: {:ok, %{}}
    @impl true
    def update_workflow_status(_id, _status), do: {:ok, %{}}
    @impl true
    def get_workflow(_id), do: {:error, :not_found}
    @impl true
    def start_step(_attrs), do: {:ok, %{}}
    @impl true
    def commit_step(_id, _output), do: {:ok, %{}}
    @impl true
    def fail_step(_id, _error), do: {:ok, %{}}
    @impl true
    def cancel_step(_id), do: {:ok, %{}}
    @impl true
    def list_pending_workflows(), do: {:ok, []}
    @impl true
    def list_steps(_wid), do: {:ok, []}
    @impl true
    def list_steps(_wid, _opts), do: {:ok, []}
    @impl true
    def claim_workflow(_id, _node, _timeout), do: {:ok, :claimed}
    @impl true
    def log_error(_attrs, _opts), do: {:ok, %{}}
    @impl true
    def get_error(_id, _opts), do: {:error, :not_found}
    @impl true
    def resolve_error(_id, _opts), do: {:ok, %{}}
    @impl true
    def enqueue_repair(_attrs, _opts), do: {:ok, %{}}
    @impl true
    def dequeue_repair(_opts), do: {:ok, nil}
    @impl true
    def update_repair(_id, _attrs, _opts), do: {:ok, %{}}
    @impl true
    def record_finding(_attrs, _opts), do: {:ok, %{}}
    @impl true
    def get_finding(_id, _opts), do: {:error, :not_found}
    @impl true
    def list_findings(_sid, _opts), do: {:ok, []}
    @impl true
    def update_finding(_id, _attrs, _opts), do: {:ok, %{}}
    @impl true
    def store_persistent_memory(_attrs, _opts), do: {:ok, %{}}
    @impl true
    def get_persistent_memory(_id, _opts), do: {:error, :not_found}
    @impl true
    def list_persistent_memories(_sid, _opts), do: {:ok, []}
    @impl true
    def store_project_lesson(_attrs, _opts), do: {:ok, %{}}
    @impl true
    def get_project_lesson(_id, _opts), do: {:error, :not_found}
    @impl true
    def list_project_lessons(_opts), do: {:ok, []}
  end

  setup_all do
    {:ok, _agent} = TestStore.start_agent()

    on_exit(fn ->
      if pid = Process.whereis(TestStore) do
        Agent.stop(pid)
      end
    end)

    :ok
  end

  setup do
    TestStore.configure([], [])
    :ok
  end

  # ── Helper to build error structs ──────────────────────────────────────

  defp build_error(attrs) do
    struct(Tet.ErrorLog, %{
      id: Map.get(attrs, :id, "err_001"),
      session_id: Map.get(attrs, :session_id, "ses_001"),
      kind: Map.get(attrs, :kind, :exception),
      message: Map.get(attrs, :message, "Something went wrong"),
      status: Map.get(attrs, :status, :open)
    })
  end

  defp build_repair(attrs) do
    struct(Tet.Repair, %{
      id: Map.get(attrs, :id, "rep_001"),
      error_log_id: Map.get(attrs, :error_log_id, "err_001"),
      strategy: Map.get(attrs, :strategy, :retry),
      status: Map.get(attrs, :status, :pending)
    })
  end

  # ── build_hook/1 ───────────────────────────────────────────────────────

  describe "build_hook/1" do
    test "returns a valid pre-hook with default priority" do
      hook = RepairInspector.build_hook()

      assert %Hook{} = hook
      assert hook.id == "pre-turn-repair-inspection"
      assert hook.event_type == :pre
      assert hook.priority == 500
      assert is_function(hook.action_fn, 1)
      assert hook.description == "Pre-turn repair inspection (BD-0058)"
    end

    test "accepts custom priority" do
      hook = RepairInspector.build_hook(priority: 100)
      assert hook.priority == 100
    end
  end

  # ── classify_severity/2 ─────────────────────────────────────────────────

  describe "classify_severity/2" do
    test "returns :normal when there are no errors or repairs" do
      assert RepairInspector.classify_severity([], []) == :normal
    end

    test "returns :critical for crash errors" do
      error = build_error(%{kind: :crash})
      assert RepairInspector.classify_severity([error], []) == :critical
    end

    test "returns :critical for compile_failure errors" do
      error = build_error(%{kind: :compile_failure})
      assert RepairInspector.classify_severity([error], []) == :critical
    end

    test "returns :critical for pending patch repairs" do
      repair = build_repair(%{strategy: :patch, status: :pending})
      assert RepairInspector.classify_severity([], [repair]) == :critical
    end

    test "returns :critical for pending fallback repairs" do
      repair = build_repair(%{strategy: :fallback, status: :pending})
      assert RepairInspector.classify_severity([], [repair]) == :critical
    end

    test "returns :high for exception errors" do
      error = build_error(%{kind: :exception})
      assert RepairInspector.classify_severity([error], []) == :high
    end

    test "returns :high for remote_failure errors" do
      error = build_error(%{kind: :remote_failure})
      assert RepairInspector.classify_severity([error], []) == :high
    end

    test "returns :high for smoke_failure errors" do
      error = build_error(%{kind: :smoke_failure})
      assert RepairInspector.classify_severity([error], []) == :high
    end

    test "returns :high for any pending repair (non-critical strategy)" do
      repair = build_repair(%{strategy: :retry, status: :pending})
      assert RepairInspector.classify_severity([], [repair]) == :high
    end

    test "returns :high for human strategy pending repairs" do
      repair = build_repair(%{strategy: :human, status: :pending})
      assert RepairInspector.classify_severity([], [repair]) == :high
    end

    test "returns :normal for non-critical, non-high errors" do
      error = build_error(%{kind: :provider_error})
      assert RepairInspector.classify_severity([error], []) == :normal
    end

    test "classifier does not consider status — caller filters open items first" do
      # classify_severity operates on already-filtered open errors.
      # A crash is always critical regardless of status; the caller
      # (fetch_open_errors) decides which items to pass in.
      error = build_error(%{kind: :crash, status: :resolved})
      assert RepairInspector.classify_severity([error], []) == :critical
    end

    test "critical overrides high" do
      crash = build_error(%{kind: :crash})
      except = build_error(%{kind: :exception})
      assert RepairInspector.classify_severity([crash, except], []) == :critical
    end

    test "high overrides normal" do
      except = build_error(%{kind: :exception})
      tool = build_error(%{kind: :tool_error})
      assert RepairInspector.classify_severity([except, tool], []) == :high
    end
  end

  # ── run_inspection/1 ───────────────────────────────────────────────────

  describe "run_inspection/1 with test store" do
    test "returns {:continue, context} when no open items exist" do
      context = %{store_adapter: TestStore, session_id: "ses_001"}
      result = RepairInspector.run_inspection(context)

      assert {:continue, updated_ctx} = result
      assert updated_ctx.repair_inspection.severity == :normal
      assert updated_ctx.repair_inspection.open_errors == []
      assert updated_ctx.repair_inspection.pending_repairs == []
    end

    test "returns {:guide, _, context} with critical severity for crash errors" do
      error = build_error(%{id: "err_crash", kind: :crash})
      TestStore.configure([error], [])

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      result = RepairInspector.run_inspection(context)

      assert {:guide, message, updated_ctx} = result
      assert updated_ctx.repair_inspection.severity == :critical
      assert String.contains?(message, "CRITICAL")
      assert String.contains?(message, "Diagnose")
      assert String.contains?(message, "Ignore once")
      assert String.contains?(message, "fallback strategy")
    end

    test "returns {:guide, _, context} with critical severity for pending patch repairs" do
      repair = build_repair(%{id: "rep_patch", strategy: :patch})
      TestStore.configure([], [repair])

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      result = RepairInspector.run_inspection(context)

      assert {:guide, message, updated_ctx} = result
      assert updated_ctx.repair_inspection.severity == :critical
      assert String.contains?(message, "CRITICAL")
    end

    test "returns {:guide, _, context} with high severity for exception errors" do
      error = build_error(%{id: "err_except", kind: :exception})
      TestStore.configure([error], [])

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      result = RepairInspector.run_inspection(context)

      assert {:guide, message, updated_ctx} = result
      assert updated_ctx.repair_inspection.severity == :high
      assert String.contains?(message, "non-blocking")
    end

    test "returns {:guide, _, context} with normal severity for non-critical errors" do
      error = build_error(%{id: "err_tool", kind: :tool_error})
      TestStore.configure([error], [])

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      result = RepairInspector.run_inspection(context)

      assert {:guide, message, updated_ctx} = result
      assert updated_ctx.repair_inspection.severity == :normal
      assert String.contains?(message, "MINOR")
    end

    test "returns {:continue, context} when no session_id is provided" do
      context = %{store_adapter: TestStore}

      error = build_error(%{id: "err_any", kind: :exception})
      TestStore.configure([error], [])

      result = RepairInspector.run_inspection(context)

      assert {:continue, updated_ctx} = result
      assert updated_ctx.repair_inspection.severity == :normal
      # No session means no errors fetched, but repairs are still checked
    end

    test "pending repairs are counted and surfaced in guidance" do
      repair = build_repair(%{id: "rep_retry", strategy: :retry})
      TestStore.configure([], [repair])

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      {:guide, message, updated_ctx} = RepairInspector.run_inspection(context)

      assert updated_ctx.repair_inspection.pending_count == 1
      assert updated_ctx.repair_inspection.severity == :high
      assert String.contains?(message, "1")
    end

    test "context is augmented with :repair_inspection key" do
      context = %{store_adapter: TestStore, session_id: "ses_001", existing: :data}
      {:continue, updated_ctx} = RepairInspector.run_inspection(context)

      assert updated_ctx.existing == :data
      assert Map.has_key?(updated_ctx, :repair_inspection)
    end

    test "list_errors failure returns {:guide, ...} with warning, not {:continue}" do
      TestStore.fail_errors(:db_timeout)

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      result = RepairInspector.run_inspection(context)

      assert {:guide, message, updated_ctx} = result
      assert String.contains?(message, "WARNING")
      assert String.contains?(message, "db_timeout")
      refute updated_ctx.repair_inspection.inspection_complete?
      assert updated_ctx.repair_inspection.query_errors == [list_errors_failed: :db_timeout]
    end

    test "list_repairs failure returns {:guide, ...} with warning, not {:continue}" do
      TestStore.fail_repairs(:connection_lost)

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      result = RepairInspector.run_inspection(context)

      assert {:guide, message, updated_ctx} = result
      assert String.contains?(message, "WARNING")
      assert String.contains?(message, "connection_lost")
      refute updated_ctx.repair_inspection.inspection_complete?
      assert updated_ctx.repair_inspection.query_errors == [list_repairs_failed: :connection_lost]
    end

    test "both list_errors and list_repairs failing surfaces the first error" do
      TestStore.fail_errors(:db_crash)
      TestStore.fail_repairs(:repair_queue_down)

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      result = RepairInspector.run_inspection(context)

      # The first query (list_errors) fails, so we surface that
      assert {:guide, message, updated_ctx} = result
      assert String.contains?(message, "WARNING")
      assert String.contains?(message, "db_crash")
      refute updated_ctx.repair_inspection.inspection_complete?
      assert updated_ctx.repair_inspection.query_errors == [list_errors_failed: :db_crash]
    end

    test "inspection_complete? is true when queries succeed" do
      context = %{store_adapter: TestStore, session_id: "ses_001"}
      {:continue, updated_ctx} = RepairInspector.run_inspection(context)

      assert updated_ctx.repair_inspection.inspection_complete?
      assert updated_ctx.repair_inspection.query_errors == []
    end

    test "inspection with items and query failure is never {:continue}" do
      TestStore.fail_errors(:timeout)

      # Even with no errors configured, a query failure should give {:guide, ...}
      context = %{store_adapter: TestStore, session_id: "ses_001"}
      assert {:guide, _message, _ctx} = RepairInspector.run_inspection(context)
    end
  end

  # ── Hook integration with HookManager ─────────────────────────────────

  describe "HookManager integration" do
    setup do
      Tet.Store.Memory.reset()
      :ok
    end

    test "registers and executes as a pre-hook" do
      hook = RepairInspector.build_hook()

      registry =
        HookManager.new()
        |> HookManager.register(hook)

      assert HookManager.hook_ids(registry) == %{pre: ["pre-turn-repair-inspection"], post: []}

      # With no store_adapter in context, the hook falls back to default
      # store which may or may not have items — test that it doesn't crash
      {:ok, ctx, guides} = HookManager.execute_pre(registry, %{session_id: "ses_001"})

      assert Map.has_key?(ctx, :repair_inspection)
      assert is_list(guides) or guides == []
    end

    test "works with test store through context" do
      hook = RepairInspector.build_hook()

      registry =
        HookManager.new()
        |> HookManager.register(hook)

      error = build_error(%{id: "err_critical", kind: :crash})
      TestStore.configure([error], [])

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      {:ok, ctx, guides} = HookManager.execute_pre(registry, context)

      assert ctx.repair_inspection.severity == :critical
      assert length(guides) == 1
      assert String.contains?(List.first(guides), "CRITICAL")
    end

    test "returns {:ok, ctx, guides} for non-critical items" do
      hook = RepairInspector.build_hook()

      registry =
        HookManager.new()
        |> HookManager.register(hook)

      error = build_error(%{id: "err_tool", kind: :tool_error})
      TestStore.configure([error], [])

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      {:ok, ctx, guides} = HookManager.execute_pre(registry, context)

      assert ctx.repair_inspection.severity == :normal
      assert length(guides) == 1
    end

    test "critical items produce guide (not block) so context modifications persist" do
      hook = RepairInspector.build_hook()

      registry =
        HookManager.new()
        |> HookManager.register(hook)

      error = build_error(%{id: "err_bad", kind: :crash})
      TestStore.configure([error], [])

      context = %{store_adapter: TestStore, session_id: "ses_001"}
      {:ok, ctx, _guides} = HookManager.execute_pre(registry, context)

      # Guide actions allow execution to continue — the message guides
      # the operator, but doesn't force-block the pipeline
      assert ctx.repair_inspection.severity == :critical
    end
  end

  # ── has_critical? / has_high? ──────────────────────────────────────────

  describe "has_critical?/2" do
    test "returns true when error kind is crash" do
      error = build_error(%{kind: :crash})
      assert RepairInspector.has_critical?([error], [])
    end

    test "returns true when repair strategy is patch" do
      repair = build_repair(%{strategy: :patch})
      assert RepairInspector.has_critical?([], [repair])
    end

    test "returns false for high severity items" do
      error = build_error(%{kind: :exception})
      refute RepairInspector.has_critical?([error], [])
    end

    test "returns false for empty inputs" do
      refute RepairInspector.has_critical?([], [])
    end
  end

  describe "has_high?/2" do
    test "returns true when error kind is exception" do
      error = build_error(%{kind: :exception})
      assert RepairInspector.has_high?([error], [])
    end

    test "returns true when any repair is pending" do
      repair = build_repair(%{status: :pending})
      assert RepairInspector.has_high?([], [repair])
    end

    test "has_high? checks kind, not status — caller filters open items first" do
      # has_high? operates on already-filtered open errors.
      # An exception is always high regardless of status.
      error = build_error(%{kind: :exception, status: :resolved})
      assert RepairInspector.has_high?([error], [])
    end

    test "returns false for empty inputs" do
      refute RepairInspector.has_high?([], [])
    end
  end

  describe "critical_kinds/0 and high_kinds/0" do
    test "returns expected lists" do
      assert :crash in RepairInspector.critical_kinds()
      assert :compile_failure in RepairInspector.critical_kinds()
      assert :exception in RepairInspector.high_kinds()
      assert :remote_failure in RepairInspector.high_kinds()
      assert :smoke_failure in RepairInspector.high_kinds()
    end
  end
end
