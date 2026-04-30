defmodule Tet.PromptLabRuntimeTest do
  use ExUnit.Case, async: false

  alias Tet.PromptLabRuntimeTest.Store

  setup do
    start_supervised!(%{id: Store, start: {Store, :start_link, [[]]}})
    :ok
  end

  test "refine_prompt persists only Prompt Lab history and does not touch execution stores" do
    assert {:ok, %{refinement: refinement, history: history}} =
             Tet.refine_prompt("Run the tool and fix this",
               preset: "coding",
               store_adapter: Store,
               refinement_id: "prompt-refinement-runtime",
               history_id: "prompt-history-runtime",
               created_at: "2025-01-01T00:00:00.000Z"
             )

    assert refinement.status == "needs_clarification"

    assert refinement.warnings == [
             "Prompt Lab is read-only: it refined wording only and did not execute tools, commands, providers, patches, or file mutations."
           ]

    assert refinement.safety == %{
             "mutates_outside_prompt_history" => false,
             "provider_called" => false,
             "tools_executed" => false
           }

    assert history.id == "prompt-history-runtime"
    assert history.created_at == "2025-01-01T00:00:00.000Z"
    assert history.request.prompt == "Run the tool and fix this"
    assert history.result == refinement

    assert Store.calls() == [{:save_prompt_history, history}]
  end

  test "persist false is a pure preview and does not resolve or call the store" do
    assert {:ok, %{refinement: refinement, history: nil}} =
             Tet.refine_prompt("Implement CLI sessions list",
               preset: "coding",
               store_adapter: Store,
               persist?: false,
               refinement_id: "prompt-refinement-preview"
             )

    assert refinement.status == "improved"
    assert Store.calls() == []
  end

  test "history facade reads through Prompt Lab history callbacks only" do
    assert {:ok, []} = Tet.list_prompt_history(store_adapter: Store)

    assert {:error, :prompt_history_not_found} =
             Tet.fetch_prompt_history("missing-history", store_adapter: Store)

    assert Store.calls() == [:list_prompt_history, {:fetch_prompt_history, "missing-history"}]
  end

  defmodule Store do
    @behaviour Tet.Store

    def start_link(_opts) do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def calls do
      Agent.get(__MODULE__, &Enum.reverse/1)
    end

    @impl true
    def boundary, do: %{application: :test, adapter: __MODULE__, status: :ok}

    @impl true
    def health(_opts), do: {:ok, %{application: :test, adapter: __MODULE__, status: :ok}}

    @impl true
    def save_prompt_history(history, _opts) do
      record({:save_prompt_history, history})
      {:ok, history}
    end

    @impl true
    def list_prompt_history(_opts) do
      record(:list_prompt_history)
      {:ok, []}
    end

    @impl true
    def fetch_prompt_history(history_id, _opts) do
      record({:fetch_prompt_history, history_id})
      {:error, :prompt_history_not_found}
    end

    @impl true
    def save_message(_message, _opts), do: forbidden(:save_message)

    @impl true
    def list_messages(_session_id, _opts), do: forbidden(:list_messages)

    @impl true
    def list_sessions(_opts), do: forbidden(:list_sessions)

    @impl true
    def fetch_session(_session_id, _opts), do: forbidden(:fetch_session)

    @impl true
    def save_autosave(_autosave, _opts), do: forbidden(:save_autosave)

    @impl true
    def load_autosave(_session_id, _opts), do: forbidden(:load_autosave)

    @impl true
    def list_autosaves(_opts), do: forbidden(:list_autosaves)

    @impl true
    def save_event(_event, _opts), do: forbidden(:save_event)

    @impl true
    def list_events(_session_id, _opts), do: forbidden(:list_events)

    defp forbidden(callback) do
      record({:forbidden, callback})
      {:error, {:forbidden_prompt_lab_callback, callback}}
    end

    defp record(call) do
      Agent.update(__MODULE__, &[call | &1])
    end
  end
end
