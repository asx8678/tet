defmodule Tet.Subagent.ResultTest do
  use ExUnit.Case, async: true

  alias Tet.Subagent.Result

  describe "new/1" do
    test "builds a valid result from atom keys" do
      attrs = %{
        id: "res_001",
        task_id: "task_001",
        session_id: "ses_001",
        output: %{answer: 42, summary: "done"},
        status: :success,
        created_at: ~U[2025-05-15 10:00:00Z],
        artifacts: [%{name: "report", url: "/artifacts/report.pdf"}],
        metadata: %{source: "agent-alpha"}
      }

      assert {:ok, %Result{} = result} = Result.new(attrs)
      assert result.id == "res_001"
      assert result.task_id == "task_001"
      assert result.session_id == "ses_001"
      assert result.output == %{answer: 42, summary: "done"}
      assert result.status == :success
      assert result.artifacts == [%{name: "report", url: "/artifacts/report.pdf"}]
      assert result.metadata == %{source: "agent-alpha"}
    end

    test "builds a valid result from string keys" do
      attrs = %{
        "id" => "res_002",
        "task_id" => "task_002",
        "session_id" => "ses_002",
        "output" => %{result: "ok"},
        "status" => "partial",
        "created_at" => "2025-05-15T11:00:00Z",
        "artifacts" => [],
        "metadata" => %{}
      }

      assert {:ok, %Result{} = result} = Result.new(attrs)
      assert result.id == "res_002"
      assert result.status == :partial
    end

    test "accepts :failure status" do
      attrs = %{
        id: "res_003",
        task_id: "task_003",
        session_id: "ses_003",
        output: %{error: "something broke"},
        status: :failure,
        created_at: ~U[2025-05-15 12:00:00Z]
      }

      assert {:ok, %Result{status: :failure}} = Result.new(attrs)
    end

    test "rejects invalid status" do
      attrs = %{
        id: "res_004",
        task_id: "task_004",
        session_id: "ses_004",
        output: %{},
        status: :invalid_status,
        created_at: ~U[2025-05-15 12:00:00Z]
      }

      assert {:error, _reason} = Result.new(attrs)
    end

    test "rejects missing required fields" do
      assert {:error, _reason} = Result.new(%{})
    end

    test "rejects missing id" do
      attrs = %{
        task_id: "task_005",
        session_id: "ses_005",
        output: %{},
        status: :success,
        created_at: ~U[2025-05-15 12:00:00Z]
      }

      assert {:error, _reason} = Result.new(attrs)
    end

    test "rejects non-map output" do
      attrs = %{
        id: "res_005",
        task_id: "task_005",
        session_id: "ses_005",
        output: "not a map",
        status: :success,
        created_at: ~U[2025-05-15 12:00:00Z]
      }

      assert {:error, _reason} = Result.new(attrs)
    end

    test "defaults artifacts to empty list" do
      attrs = %{
        id: "res_006",
        task_id: "task_006",
        session_id: "ses_006",
        output: %{},
        status: :success,
        created_at: ~U[2025-05-15 12:00:00Z]
      }

      assert {:ok, %Result{artifacts: []}} = Result.new(attrs)
    end

    test "defaults metadata to empty map" do
      attrs = %{
        id: "res_007",
        task_id: "task_007",
        session_id: "ses_007",
        output: %{},
        status: :success,
        created_at: ~U[2025-05-15 12:00:00Z]
      }

      assert {:ok, %Result{metadata: %{}}} = Result.new(attrs)
    end
  end

  describe "to_map/1" do
    test "converts result to a map with atom keys and string enums" do
      result = build_result()

      map = Result.to_map(result)

      assert map.id == "res_map_001"
      assert map.task_id == "task_map_001"
      assert map.session_id == "ses_map_001"
      assert map.output == %{answer: 42}
      assert map.status == "success"
      assert map.created_at == "2025-05-15T14:00:00Z"
      assert map.metadata == %{source: "test"}
      assert is_list(map.artifacts)
    end
  end

  describe "from_map/1" do
    test "round-trips through to_map" do
      original = build_result()
      map = Result.to_map(original)
      assert {:ok, ^original} = Result.from_map(map)
    end

    test "handles failure status round-trip" do
      attrs = %{
        id: "res_ft_001",
        task_id: "task_ft_001",
        session_id: "ses_ft_001",
        output: %{error: "fail"},
        status: :failure,
        created_at: ~U[2025-05-15 15:00:00Z]
      }

      assert {:ok, result} = Result.new(attrs)
      map = Result.to_map(result)
      assert {:ok, restored} = Result.from_map(map)
      assert restored == result
    end

    test "handles partial status round-trip" do
      attrs = %{
        id: "res_ft_002",
        task_id: "task_ft_002",
        session_id: "ses_ft_002",
        output: %{partial: true},
        status: :partial,
        created_at: ~U[2025-05-15 16:00:00Z]
      }

      assert {:ok, result} = Result.new(attrs)
      map = Result.to_map(result)
      assert {:ok, restored} = Result.from_map(map)
      assert restored == result
    end
  end

  describe "statuses/0" do
    test "returns list of valid status atoms" do
      assert Result.statuses() == [:success, :failure, :partial]
    end
  end

  defp build_result do
    {:ok, result} =
      Result.new(%{
        id: "res_map_001",
        task_id: "task_map_001",
        session_id: "ses_map_001",
        output: %{answer: 42},
        status: :success,
        created_at: ~U[2025-05-15 14:00:00Z],
        artifacts: [%{name: "test_artifact"}],
        metadata: %{source: "test"}
      })

    result
  end
end
