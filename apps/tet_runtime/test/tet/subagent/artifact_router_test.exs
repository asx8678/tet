defmodule Tet.Runtime.Subagent.ArtifactRouterTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Subagent.ArtifactRouter
  alias Tet.Subagent.Result

  # ── Mock store for testing ───────────────────────────────────────────

  defmodule TestStore do
    @moduledoc false

    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{created: []} end, name: __MODULE__)
    end

    def create_artifact(attrs, _opts) when is_map(attrs) do
      id = Map.get(attrs, :id) || "art_test_#{:erlang.unique_integer()}"
      artifact = Map.put(attrs, :id, id)

      Agent.update(__MODULE__, fn state ->
        %{state | created: [artifact | state.created]}
      end)

      {:ok, artifact}
    end

    def get_created_artifacts do
      Agent.get(__MODULE__, fn state -> Enum.reverse(state.created) end)
    end

    def clear do
      Agent.update(__MODULE__, fn _state -> %{created: []} end)
    end
  end

  setup_all do
    case TestStore.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    TestStore.clear()
    :ok
  end

  describe "route/3 with Result struct" do
    test "routes artifacts from a Tet.Subagent.Result struct" do
      {:ok, result} =
        Result.new(%{
          id: "res_art_001",
          task_id: "task_art_001",
          session_id: "ses_art_001",
          output: %{result: "ok"},
          status: :success,
          created_at: ~U[2025-05-15 10:00:00Z],
          artifacts: [
            %{id: "art_001", kind: "stdout", content: "hello world", sha256: "abc123"},
            %{kind: "diff", content: "patch content", sha256: "def456"}
          ],
          metadata: %{correlation_id: "corr_123"}
        })

      assert {:ok, artifacts} = ArtifactRouter.route(TestStore, [], result)
      assert length(artifacts) == 2

      stored = TestStore.get_created_artifacts()
      assert length(stored) == 2
    end

    test "attaches routing metadata to each artifact" do
      {:ok, result} =
        Result.new(%{
          id: "res_art_002",
          task_id: "task_art_002",
          session_id: "ses_art_002",
          output: %{},
          status: :success,
          created_at: ~U[2025-05-15 10:00:00Z],
          artifacts: [
            %{kind: "stdout", content: "output", sha256: "sha123"}
          ],
          metadata: %{correlation_id: "corr_456"}
        })

      assert {:ok, [artifact]} = ArtifactRouter.route(TestStore, [], result)

      assert artifact.session_id == "ses_art_002"
      assert artifact.task_id == "task_art_002"
      assert artifact.metadata[:routed_from_subagent] == "res_art_002"
      assert artifact.metadata[:correlation_id] == "corr_456"
      assert is_binary(artifact.metadata[:routed_at])
    end

    test "handles result with no artifacts" do
      {:ok, result} =
        Result.new(%{
          id: "res_art_003",
          task_id: "task_art_003",
          session_id: "ses_art_003",
          output: %{},
          status: :success,
          created_at: ~U[2025-05-15 10:00:00Z]
        })

      assert {:ok, []} = ArtifactRouter.route(TestStore, [], result)
    end

    test "generates artifact id if none provided" do
      {:ok, result} =
        Result.new(%{
          id: "res_art_004",
          task_id: "task_art_004",
          session_id: "ses_art_004",
          output: %{},
          status: :success,
          created_at: ~U[2025-05-15 10:00:00Z],
          artifacts: [
            %{kind: "stdout", content: "data", sha256: "sha789"}
          ]
        })

      assert {:ok, [artifact]} = ArtifactRouter.route(TestStore, [], result)
      assert is_binary(artifact.id)
    end
  end

  describe "route/3 with map" do
    test "routes artifacts from a plain map" do
      result = %{
        "id" => "res_map_001",
        "task_id" => "task_map_001",
        "session_id" => "ses_map_001",
        "output" => %{},
        "status" => "success",
        "artifacts" => [
          %{"kind" => "report", "content" => "data", "sha256" => "abc"}
        ]
      }

      assert {:ok, [artifact]} = ArtifactRouter.route(TestStore, [], result)
      assert artifact.session_id == "ses_map_001"
      assert artifact.task_id == "task_map_001"
    end

    test "uses id from map as source subagent" do
      result = %{
        "id" => "res_map_002",
        "task_id" => "task_map_002",
        "session_id" => "ses_map_002",
        "output" => %{},
        "status" => "success",
        "artifacts" => [
          %{"kind" => "data", "content" => "stuff", "sha256" => "def"}
        ]
      }

      assert {:ok, [artifact]} = ArtifactRouter.route(TestStore, [], result)
      assert artifact.metadata[:routed_from_subagent] == "res_map_002"
    end

    test "handles empty artifacts list" do
      result = %{
        "id" => "res_map_003",
        "task_id" => "task_map_003",
        "session_id" => "ses_map_003",
        "output" => %{},
        "status" => "success",
        "artifacts" => []
      }

      assert {:ok, []} = ArtifactRouter.route(TestStore, [], result)
    end
  end

  describe "route_single/4" do
    test "routes a single artifact with routing metadata" do
      artifact_map = %{kind: "stdout", content: "single", sha256: "xyz789"}

      routing = %{
        source_subagent: "res_single_001",
        session_id: "ses_single_001",
        task_id: "task_single_001",
        correlation_id: "corr_single"
      }

      assert {:ok, artifact} = ArtifactRouter.route_single(TestStore, [], artifact_map, routing)

      assert artifact.session_id == "ses_single_001"
      assert artifact.task_id == "task_single_001"
      assert artifact.metadata[:routed_from_subagent] == "res_single_001"
      assert artifact.metadata[:correlation_id] == "corr_single"
      assert is_binary(artifact.id)
    end

    test "generates id if not provided in artifact map" do
      artifact_map = %{kind: "log", content: "log data", sha256: "aaa111"}

      routing = %{
        source_subagent: "res_single_002",
        session_id: "ses_single_002",
        task_id: "task_single_002"
      }

      assert {:ok, artifact} = ArtifactRouter.route_single(TestStore, [], artifact_map, routing)
      assert is_binary(artifact.id)
      assert String.starts_with?(artifact.id, "art_")
    end

    test "uses source_subagent as correlation_id when not provided" do
      artifact_map = %{kind: "log", content: "data", sha256: "bbb222"}

      routing = %{
        source_subagent: "res_single_003",
        session_id: "ses_single_003",
        task_id: "task_single_003"
      }

      assert {:ok, artifact} = ArtifactRouter.route_single(TestStore, [], artifact_map, routing)
      assert artifact.metadata[:correlation_id] == "res_single_003"
    end
  end

  describe "error handling" do
    test "returns error for invalid result" do
      assert {:error, :invalid_result} = ArtifactRouter.route(TestStore, [], "not_a_map")
    end
  end

  describe "route/3 with real Tet.Store.Memory" do
    setup do
      {:ok, _started} = Application.ensure_all_started(:tet_store_memory)
      Tet.Store.Memory.reset()
      :ok
    end

    test "routes artifacts and stores them as proper Artifact structs" do
      result = %{
        "id" => "res_real_001",
        "task_id" => "task_real_001",
        "session_id" => "ses_real_001",
        "output" => %{},
        "status" => "success",
        "artifacts" => [
          %{"kind" => "stdout", "content" => "hello from real store"}
        ]
      }

      assert {:ok, [artifact]} = ArtifactRouter.route(Tet.Store.Memory, [], result)

      # Should be a proper Artifact struct
      assert %Tet.ShellPolicy.Artifact{} = artifact
      assert artifact.session_id == "ses_real_001"
      assert artifact.task_id == "task_real_001"
      assert artifact.command == ["unknown"]
      assert artifact.risk == :medium
      assert artifact.exit_code == 0
      assert artifact.stdout == ""
      assert artifact.cwd == "/"
      assert artifact.duration_ms == 0
      assert is_binary(artifact.tool_call_id)
      assert artifact.metadata[:routed_from_subagent] == "res_real_001"
    end

    test "routes artifacts from Result struct through real store" do
      {:ok, result} =
        Result.new(%{
          id: "res_real_002",
          task_id: "task_real_002",
          session_id: "ses_real_002",
          output: %{},
          status: :success,
          created_at: ~U[2025-05-15 10:00:00Z],
          artifacts: [
            %{kind: "stdout", command: ["echo", "hi"], risk: :low, stdout: "hello output"}
          ]
        })

      assert {:ok, [artifact]} = ArtifactRouter.route(Tet.Store.Memory, [], result)

      assert %Tet.ShellPolicy.Artifact{} = artifact
      assert artifact.command == ["echo", "hi"]
      assert artifact.risk == :low
      assert artifact.session_id == "ses_real_002"
      assert artifact.stdout == "hello output"
    end

    test "returns error for artifact with invalid required fields" do
      result = %{
        "id" => "res_real_003",
        "task_id" => "task_real_003",
        "session_id" => "ses_real_003",
        "output" => %{},
        "status" => "success",
        "artifacts" => [
          %{"kind" => "bad", "command" => "not_a_list"}
        ]
      }

      assert {:error, {:invalid_artifact_field, :command}} =
               ArtifactRouter.route(Tet.Store.Memory, [], result)
    end
  end
end
