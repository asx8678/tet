defmodule Tet.Runtime.Command.GateTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Runtime.Command.Gate
  alias Tet.Command.Suggestion

  describe "assess/2" do
    test "assesses a safe command" do
      assert {:ok, suggestion} = Gate.assess("ls -la", %{})
      assert suggestion.risk_level == :none
      assert suggestion.requires_gate == false
    end

    test "assesses a critical command" do
      assert {:ok, suggestion} = Gate.assess("rm -rf /", %{})
      assert suggestion.risk_level == :critical
      assert suggestion.requires_gate == true
      assert suggestion.correction_type == :blocked
    end

    test "assesses a high-risk command" do
      assert {:ok, suggestion} = Gate.assess("rm file.txt", %{})
      assert suggestion.risk_level == :high
      assert suggestion.requires_gate == true
      assert suggestion.correction_type == :modified
    end

    test "assesses a medium command" do
      assert {:ok, suggestion} = Gate.assess("sed -i 's/foo/bar/' config.txt", %{})
      assert suggestion.risk_level == :medium
      assert suggestion.requires_gate == false
    end

    test "assesses a low command" do
      assert {:ok, suggestion} = Gate.assess("mkdir new_dir", %{})
      assert suggestion.risk_level == :low
      assert suggestion.requires_gate == false
    end

    test "works without context" do
      assert {:ok, suggestion} = Gate.assess("pwd")
      assert suggestion.risk_level == :none
    end
  end

  describe "require_approval?/1" do
    test "returns true for critical Suggestion" do
      {:ok, suggestion} =
        Suggestion.new(%{
          original_command: "rm -rf /",
          risk_level: :critical,
          reason: "test",
          requires_gate: true,
          correction_type: :blocked
        })

      assert Gate.require_approval?(suggestion) == true
    end

    test "returns true for high Suggestion" do
      {:ok, suggestion} =
        Suggestion.new(%{
          original_command: "rm file.txt",
          risk_level: :high,
          reason: "test",
          requires_gate: true,
          correction_type: :modified
        })

      assert Gate.require_approval?(suggestion) == true
    end

    test "returns false for none Suggestion" do
      {:ok, suggestion} =
        Suggestion.new(%{
          original_command: "ls",
          risk_level: :none,
          reason: "test",
          requires_gate: false,
          correction_type: :safe
        })

      assert Gate.require_approval?(suggestion) == false
    end

    test "returns false for medium Suggestion" do
      {:ok, suggestion} =
        Suggestion.new(%{
          original_command: "sed -i 's/foo/bar/'",
          risk_level: :medium,
          reason: "test",
          requires_gate: false,
          correction_type: :modified
        })

      assert Gate.require_approval?(suggestion) == false
    end
  end

  describe "execute_or_defer/2" do
    test "executes safe commands directly" do
      {:ok, suggestion} = Gate.assess("ls -la", %{})

      assert {:ok, ^suggestion, :executed} = Gate.execute_or_defer(suggestion)
    end

    test "defers dangerous commands when defer is true" do
      {:ok, suggestion} = Gate.assess("rm -rf /", %{})

      assert {:ok, ^suggestion, :deferred} = Gate.execute_or_defer(suggestion, defer: true)
    end

    test "errors on dangerous commands without defer" do
      {:ok, suggestion} = Gate.assess("rm -rf /", %{})

      assert {:error, _} = Gate.execute_or_defer(suggestion)
    end

    test "executes dangerous commands with force flag" do
      {:ok, suggestion} = Gate.assess("rm -rf /", %{})

      assert {:ok, ^suggestion, :executed} = Gate.execute_or_defer(suggestion, force: true)
    end

    test "executes medium commands directly" do
      {:ok, suggestion} = Gate.assess("sed -i 's/foo/bar/' config.txt", %{})

      assert {:ok, ^suggestion, :executed} = Gate.execute_or_defer(suggestion)
    end
  end

  describe "classify/1" do
    test "delegates classification" do
      assert Gate.classify("ls") == :none
      assert Gate.classify("rm -rf /") == :critical
      assert Gate.classify("rm file.txt") == :high
      assert Gate.classify("sed -i 's/foo/bar/'") == :medium
      assert Gate.classify("mkdir foo") == :low
    end
  end

  describe "GenServer integration" do
    test "start_link and call assess" do
      {:ok, _pid} = Gate.start_link(name: :gate_test)

      assert {:ok, suggestion} = Gate.assess("echo hi", %{})
      assert suggestion.risk_level == :none
    end
  end
end
