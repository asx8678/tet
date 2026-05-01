defmodule Tet.Command.SuggestionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Command.Suggestion

  describe "new/1" do
    test "builds a valid suggestion from required attrs" do
      attrs = %{
        original_command: "rm -rf /tmp/foo",
        suggested_command: "mv /tmp/foo ~/.Trash/foo",
        risk_level: :critical,
        reason: "Use move to trash instead of permanent deletion",
        requires_gate: true,
        correction_type: :modified
      }

      assert {:ok, suggestion} = Suggestion.new(attrs)
      assert suggestion.original_command == "rm -rf /tmp/foo"
      assert suggestion.suggested_command == "mv /tmp/foo ~/.Trash/foo"
      assert suggestion.risk_level == :critical
      assert suggestion.reason == "Use move to trash instead of permanent deletion"
      assert suggestion.requires_gate == true
      assert suggestion.correction_type == :modified
    end

    test "builds a suggestion without suggested_command" do
      attrs = %{
        original_command: "ls -la",
        risk_level: :none,
        reason: "Safe operation",
        requires_gate: false,
        correction_type: :safe
      }

      assert {:ok, suggestion} = Suggestion.new(attrs)
      assert suggestion.original_command == "ls -la"
      assert suggestion.suggested_command == nil
      assert suggestion.risk_level == :none
    end

    test "accepts all valid risk levels" do
      for risk_level <- [:none, :low, :medium, :high, :critical] do
        attrs = %{
          original_command: "test",
          risk_level: risk_level,
          reason: "test",
          requires_gate: risk_level in [:high, :critical],
          correction_type: :safe
        }

        assert {:ok, suggestion} = Suggestion.new(attrs)
        assert suggestion.risk_level == risk_level
      end
    end

    test "accepts all valid correction types" do
      for correction_type <- [:safe, :modified, :blocked] do
        attrs = %{
          original_command: "test",
          risk_level: :low,
          reason: "test",
          requires_gate: false,
          correction_type: correction_type
        }

        assert {:ok, suggestion} = Suggestion.new(attrs)
        assert suggestion.correction_type == correction_type
      end
    end

    test "rejects missing required fields" do
      assert {:error, _} = Suggestion.new(%{})
    end

    test "rejects invalid risk level" do
      attrs = %{
        original_command: "test",
        risk_level: :extreme,
        reason: "test",
        requires_gate: false,
        correction_type: :safe
      }

      assert {:error, _} = Suggestion.new(attrs)
    end

    test "rejects invalid correction type" do
      attrs = %{
        original_command: "test",
        risk_level: :low,
        reason: "test",
        requires_gate: false,
        correction_type: :invalid
      }

      assert {:error, _} = Suggestion.new(attrs)
    end

    test "rejects non-boolean requires_gate" do
      attrs = %{
        original_command: "test",
        risk_level: :low,
        reason: "test",
        requires_gate: "yes",
        correction_type: :safe
      }

      assert {:error, _} = Suggestion.new(attrs)
    end

    test "accepts string risk level via String.to_existing_atom" do
      attrs = %{
        original_command: "test",
        risk_level: "high",
        reason: "test",
        requires_gate: true,
        correction_type: "blocked"
      }

      assert {:ok, suggestion} = Suggestion.new(attrs)
      assert suggestion.risk_level == :high
      assert suggestion.correction_type == :blocked
    end
  end

  describe "new!/1" do
    test "builds or raises" do
      attrs = %{
        original_command: "echo hi",
        risk_level: :none,
        reason: "test",
        requires_gate: false,
        correction_type: :safe
      }

      assert %Suggestion{} = Suggestion.new!(attrs)
    end

    test "raises on invalid attrs" do
      assert_raise ArgumentError, fn ->
        Suggestion.new!(%{original_command: "test"})
      end
    end
  end

  describe "to_map/1" do
    test "converts to JSON-friendly map" do
      attrs = %{
        original_command: "rm -rf /tmp/foo",
        suggested_command: "mv /tmp/foo ~/.Trash/foo",
        risk_level: :critical,
        reason: "Use move to trash",
        requires_gate: true,
        correction_type: :modified
      }

      {:ok, suggestion} = Suggestion.new(attrs)
      map = Suggestion.to_map(suggestion)

      assert map.original_command == "rm -rf /tmp/foo"
      assert map.suggested_command == "mv /tmp/foo ~/.Trash/foo"
      assert map.risk_level == "critical"
      assert map.reason == "Use move to trash"
      assert map.requires_gate == true
      assert map.correction_type == "modified"
    end

    test "handles nil suggested_command" do
      attrs = %{
        original_command: "ls",
        risk_level: :none,
        reason: "Safe",
        requires_gate: false,
        correction_type: :safe
      }

      {:ok, suggestion} = Suggestion.new(attrs)
      map = Suggestion.to_map(suggestion)

      assert map.suggested_command == nil
      assert map.risk_level == "none"
      assert map.correction_type == "safe"
    end
  end

  describe "from_map/1" do
    test "restores from a map with atom keys" do
      map = %{
        original_command: "rm -rf /tmp/foo",
        suggested_command: "mv /tmp/foo ~/.Trash/foo",
        risk_level: :critical,
        reason: "Use move to trash",
        requires_gate: true,
        correction_type: :modified
      }

      assert {:ok, suggestion} = Suggestion.from_map(map)
      assert suggestion.original_command == "rm -rf /tmp/foo"
      assert suggestion.risk_level == :critical
    end

    test "restores from a map with string keys" do
      map = %{
        "original_command" => "ls -la",
        "suggested_command" => nil,
        "risk_level" => "none",
        "reason" => "Safe",
        "requires_gate" => false,
        "correction_type" => "safe"
      }

      assert {:ok, suggestion} = Suggestion.from_map(map)
      assert suggestion.original_command == "ls -la"
      assert suggestion.risk_level == :none
      assert suggestion.requires_gate == false
    end
  end
end
