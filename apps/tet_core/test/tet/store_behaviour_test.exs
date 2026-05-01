defmodule Tet.StoreBehaviourTest do
  use ExUnit.Case, async: true

  defmodule NoopStore do
    @behaviour Tet.Store

    @impl true
    def boundary, do: %{adapter: __MODULE__}

    @impl true
    def health(_opts) do
      {:ok, %{application: :tet_core, adapter: __MODULE__, status: :ok}}
    end

    @impl true
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    @impl true
    def create_workspace(_attrs), do: {:error, :not_implemented}

    @impl true
    def get_workspace(_workspace_id), do: {:error, :not_implemented}

    @impl true
    def set_trust(_workspace_id, _trust_state), do: {:error, :not_implemented}

    @impl true
    def create_session(_attrs), do: {:error, :not_implemented}

    @impl true
    def update_session(_session_id, _attrs), do: {:error, :not_implemented}

    @impl true
    def get_session(_session_id), do: {:error, :not_implemented}

    @impl true
    def list_sessions(_workspace_id), do: {:ok, []}

    @impl true
    def create_task(_attrs), do: {:error, :not_implemented}

    @impl true
    def append_message(_attrs), do: {:error, :not_implemented}

    @impl true
    def record_tool_run(_attrs), do: {:error, :not_implemented}

    @impl true
    def update_tool_run(_tool_run_id, _attrs), do: {:error, :not_implemented}

    @impl true
    def create_approval(_attrs), do: {:error, :not_implemented}

    @impl true
    def resolve_approval(_approval_id, _resolution, _attrs), do: {:error, :not_implemented}

    @impl true
    def get_approval(_approval_id), do: {:error, :not_implemented}

    @impl true
    def list_approvals(_session_id, _opts), do: {:ok, []}

    @impl true
    def create_artifact(_attrs), do: {:error, :not_implemented}

    @impl true
    def get_artifact(_artifact_id), do: {:error, :not_implemented}

    @impl true
    def emit_event(_attrs), do: {:error, :not_implemented}

    @impl true
    def list_events(_session_id, _opts), do: {:ok, []}

    @impl true
    def create_workflow(_attrs), do: {:error, :not_implemented}

    @impl true
    def update_workflow_status(_workflow_id, _status), do: {:error, :not_implemented}

    @impl true
    def get_workflow(_workflow_id), do: {:error, :not_implemented}

    @impl true
    def start_step(_attrs), do: {:error, :not_implemented}

    @impl true
    def commit_step(_step_id, _output), do: {:error, :not_implemented}

    @impl true
    def fail_step(_step_id, _error), do: {:error, :not_implemented}

    @impl true
    def cancel_step(_step_id), do: {:error, :not_implemented}

    @impl true
    def list_pending_workflows, do: {:ok, []}

    @impl true
    def list_steps(_workflow_id), do: {:ok, []}

    @impl true
    def claim_workflow(_workflow_id, _node, _ttl_ms), do: {:ok, :claimed}

    @impl true
    def save_message(message, _opts), do: {:ok, message}

    @impl true
    def list_messages(_session_id, _opts), do: {:ok, []}

    @impl true
    def fetch_session(_session_id, _opts), do: {:error, :not_implemented}

    @impl true
    def save_autosave(autosave, _opts), do: {:ok, autosave}

    @impl true
    def load_autosave(_session_id, _opts), do: {:error, :not_implemented}

    @impl true
    def list_autosaves(_opts), do: {:ok, []}

    @impl true
    def save_event(event, _opts), do: {:ok, event}

    @impl true
    def save_prompt_history(history, _opts), do: {:ok, history}

    @impl true
    def list_prompt_history(_opts), do: {:ok, []}

    @impl true
    def fetch_prompt_history(_history_id, _opts), do: {:error, :not_implemented}
  end

  test "the full v0.3 store behaviour is implementable" do
    assert {:ok, :committed} = NoopStore.transaction(fn -> :committed end)
    assert {:ok, []} = NoopStore.list_events("ses_test", [])
    assert {:error, :not_implemented} = NoopStore.create_workflow(%{})
    assert {:error, :not_implemented} = NoopStore.update_workflow_status("wf_test", :running)
    assert {:error, :not_implemented} = NoopStore.get_workflow("wf_test")
    assert {:ok, :claimed} = NoopStore.claim_workflow("wf_test", node(), 1_000)
  end
end
