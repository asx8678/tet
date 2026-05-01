defmodule Tet.Runtime.Subagent.ResultMergeTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Subagent.ResultMerge
  alias Tet.Subagent.Result

  describe "merge/3 with :first_wins strategy (default)" do
    test "earlier result takes precedence for same output field" do
      parent = %{output: %{answer: 42}}
      later = %{output: %{answer: 100}}

      assert {:ok, merged} = ResultMerge.merge(parent, later)
      assert merged[:output][:answer] == 42
    end

    test "later result adds new fields not present in parent" do
      parent = %{output: %{answer: 42}}
      later = %{output: %{summary: "done"}}

      assert {:ok, merged} = ResultMerge.merge(parent, later)
      assert merged[:output][:answer] == 42
      assert merged[:output][:summary] == "done"
    end

    test "accumulates artifacts from both parent and result" do
      parent = %{output: %{}, artifacts: [%{id: "art_1"}]}
      later = %{output: %{}, artifacts: [%{id: "art_2"}, %{id: "art_3"}]}

      assert {:ok, merged} = ResultMerge.merge(parent, later)
      assert length(merged[:artifacts]) == 3
    end

    test "parent metadata takes precedence over result metadata" do
      parent = %{output: %{}, metadata: %{source: "parent"}}
      later = %{output: %{}, metadata: %{source: "child"}}

      assert {:ok, merged} = ResultMerge.merge(parent, later)
      assert merged[:metadata][:source] == "parent"
    end

    test "result metadata adds new keys to parent" do
      parent = %{output: %{}, metadata: %{source: "parent"}}
      later = %{output: %{}, metadata: %{version: 2}}

      assert {:ok, merged} = ResultMerge.merge(parent, later)
      assert merged[:metadata][:source] == "parent"
      assert merged[:metadata][:version] == 2
    end

    test "status cascade: failure dominates" do
      parent = %{output: %{}}
      later = %{output: %{}, status: "failure"}

      assert {:ok, merged} = ResultMerge.merge(parent, later)
      assert merged[:status] == :failure
    end

    test "status cascade: partial with success stays partial" do
      parent = %{output: %{}, status: "partial"}
      later = %{output: %{}, status: "success"}

      assert {:ok, merged} = ResultMerge.merge(parent, later)
      assert merged[:status] == :partial
    end

    test "status cascade: later failure overrides earlier partial" do
      parent = %{output: %{}, status: "partial"}
      later = %{output: %{}, status: "failure"}

      assert {:ok, merged} = ResultMerge.merge(parent, later)
      assert merged[:status] == :failure
    end
  end

  describe "merge/3 with :last_wins strategy" do
    test "later result overwrites earlier value for same field" do
      parent = %{output: %{answer: 42}}
      later = %{output: %{answer: 100}}

      assert {:ok, merged} = ResultMerge.merge(parent, later, strategy: :last_wins)
      assert merged[:output][:answer] == 100
    end

    test "later result adds new fields" do
      parent = %{output: %{answer: 42}}
      later = %{output: %{summary: "done"}}

      assert {:ok, merged} = ResultMerge.merge(parent, later, strategy: :last_wins)
      assert merged[:output][:answer] == 42
      assert merged[:output][:summary] == "done"
    end
  end

  describe "merge/3 with :merge_maps strategy" do
    test "deep merges nested maps" do
      parent = %{output: %{config: %{host: "localhost", port: 8080}}}
      later = %{output: %{config: %{host: "remote", debug: true}}}

      assert {:ok, merged} =
               ResultMerge.merge(parent, later,
                 strategy: :merge_maps,
                 on_scalar_conflict: :last_wins
               )

      assert merged[:output][:config][:host] == "remote"
      assert merged[:output][:config][:port] == 8080
      assert merged[:output][:config][:debug] == true
    end

    test "merge_maps with :first_wins scalar conflict preserves parent values" do
      parent = %{output: %{config: %{host: "localhost", version: 1}}}
      later = %{output: %{config: %{host: "remote", debug: true}}}

      assert {:ok, merged} =
               ResultMerge.merge(parent, later,
                 strategy: :merge_maps,
                 on_scalar_conflict: :first_wins
               )

      assert merged[:output][:config][:host] == "localhost"
      assert merged[:output][:config][:version] == 1
      assert merged[:output][:config][:debug] == true
    end

    test "non-map values are not merged" do
      parent = %{output: %{simple_field: 42}}
      later = %{output: %{simple_field: 100, new_field: "ok"}}

      assert {:ok, merged} =
               ResultMerge.merge(parent, later,
                 strategy: :merge_maps,
                 on_scalar_conflict: :first_wins
               )

      assert merged[:output][:simple_field] == 42
      assert merged[:output][:new_field] == "ok"
    end
  end

  describe "merge/3 with Result struct" do
    test "merges from a Tet.Subagent.Result struct" do
      parent = %{output: %{existing: true}}

      {:ok, result} =
        Result.new(%{
          id: "res_merge_001",
          task_id: "task_m_001",
          session_id: "ses_m_001",
          output: %{new_data: "from_subagent"},
          status: :success,
          created_at: ~U[2025-05-15 10:00:00Z]
        })

      assert {:ok, merged} = ResultMerge.merge(parent, result)
      assert merged[:output][:existing] == true
      assert merged[:output][:new_data] == "from_subagent"
    end
  end

  describe "merge/3 error handling" do
    test "returns error for invalid strategy" do
      parent = %{output: %{}}
      later = %{output: %{}}

      assert {:error, {:invalid_merge_strategy, :unknown}} =
               ResultMerge.merge(parent, later, strategy: :unknown)
    end

    test "returns error for invalid on_scalar_conflict" do
      parent = %{output: %{}}
      later = %{output: %{}}

      assert {:error, {:invalid_scalar_conflict_strategy, :invalid}} =
               ResultMerge.merge(parent, later,
                 strategy: :merge_maps,
                 on_scalar_conflict: :invalid
               )
    end

    test "returns error for invalid result" do
      assert {:error, :invalid_result} = ResultMerge.merge(%{}, "not a result")
    end
  end

  describe "validate/1" do
    test "accepts valid state with map output" do
      assert :ok = ResultMerge.validate(%{output: %{}, artifacts: [], status: :success})
    end

    test "accepts valid state with nil output" do
      assert :ok = ResultMerge.validate(%{output: nil, artifacts: [], status: nil})
    end

    test "accepts valid state with string status" do
      assert :ok = ResultMerge.validate(%{output: %{}, artifacts: [], status: "success"})
    end

    test "rejects non-map output" do
      assert {:error, {:invalid_output_type, _}} =
               ResultMerge.validate(%{output: "bad", artifacts: [], status: nil})
    end

    test "rejects non-list artifacts" do
      assert {:error, {:invalid_artifacts_type, _}} =
               ResultMerge.validate(%{output: %{}, artifacts: "bad", status: nil})
    end

    test "rejects invalid status value" do
      assert {:error, {:invalid_status_value, :bad_status}} =
               ResultMerge.validate(%{output: %{}, artifacts: [], status: :bad_status})
    end

    test "rejects non-map state" do
      assert {:error, :invalid_state} = ResultMerge.validate("not a map")
    end
  end
end
