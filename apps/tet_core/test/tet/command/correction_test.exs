defmodule Tet.Command.CorrectionTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Command.{Correction, Suggestion}

  describe "suggest/2" do
    test "returns suggestions for :critical rm -rf /" do
      [suggestion | _] = Correction.suggest("rm -rf /", %{})
      assert suggestion.risk_level == :critical
      assert suggestion.requires_gate == true
      assert suggestion.correction_type == :blocked
      assert suggestion.original_command == "rm -rf /"
    end

    test "returns suggestions for :critical rm -rf with path" do
      [suggestion | _] = Correction.suggest("rm -rf /tmp/foo", %{})
      assert suggestion.risk_level == :critical
      assert suggestion.requires_gate == true
      assert suggestion.correction_type == :modified
      assert String.contains?(suggestion.suggested_command || "", "mv")
    end

    test "returns blocked suggestion for DROP TABLE" do
      [blocked | _] = Correction.suggest("DROP TABLE users;", %{})
      assert blocked.risk_level == :critical
      assert blocked.requires_gate == true
      assert blocked.correction_type == :blocked
    end

    test "returns blocked suggestion for dd" do
      [suggestion | _] = Correction.suggest("dd if=/dev/zero of=/dev/sda bs=4M", %{})
      assert suggestion.risk_level == :critical
      assert suggestion.requires_gate == true
      assert suggestion.correction_type == :blocked
    end

    test "returns modified suggestion for rm file with suggestions" do
      suggestions = Correction.suggest("rm file.txt", %{})
      assert length(suggestions) >= 2

      [first | _] = suggestions
      assert first.risk_level == :high
      assert first.requires_gate == true
      assert first.correction_type == :modified
      assert String.contains?(first.suggested_command || "", "Trash")
    end

    test "returns modified suggestion for chmod 777" do
      suggestions = Correction.suggest("chmod 777 script.sh", %{})
      assert length(suggestions) >= 1

      [first | _] = suggestions
      assert first.risk_level == :high
      assert first.requires_gate == true
      assert first.correction_type == :modified
    end

    test "returns modified suggestion for DELETE without WHERE" do
      [suggestion | _] = Correction.suggest("DELETE FROM users", %{})
      assert suggestion.risk_level == :high
      assert suggestion.requires_gate == true
      assert suggestion.correction_type == :modified
      assert String.contains?(suggestion.suggested_command || "", "WHERE")
    end

    test "returns modified suggestion for UPDATE without WHERE" do
      [suggestion | _] = Correction.suggest("UPDATE users SET name = 'admin'", %{})
      assert suggestion.risk_level == :high
      assert suggestion.requires_gate == true
      assert suggestion.correction_type == :modified
      assert String.contains?(suggestion.suggested_command || "", "WHERE")
    end

    test "returns :modified for medium sed -i" do
      [suggestion | _] = Correction.suggest("sed -i 's/foo/bar/' config.txt", %{})
      assert suggestion.risk_level == :medium
      assert suggestion.requires_gate == false
      assert suggestion.correction_type == :modified
    end

    test "returns :modified for medium package install" do
      [suggestion | _] = Correction.suggest("apt-get install nginx", %{})
      assert suggestion.risk_level == :medium
      assert suggestion.requires_gate == false
      assert suggestion.correction_type == :modified
    end

    test "returns :safe for low mkdir" do
      [suggestion | _] = Correction.suggest("mkdir new_dir", %{})
      assert suggestion.risk_level == :low
      assert suggestion.requires_gate == false
      assert suggestion.correction_type == :safe
    end

    test "returns :safe for :none commands" do
      [suggestion | _] = Correction.suggest("ls -la", %{})
      assert suggestion.risk_level == :none
      assert suggestion.requires_gate == false
      assert suggestion.correction_type == :safe
      assert suggestion.suggested_command == "ls -la"
    end

    test "returns :safe for echo" do
      [suggestion | _] = Correction.suggest("echo hello", %{})
      assert suggestion.risk_level == :none
      assert suggestion.requires_gate == false
      assert suggestion.correction_type == :safe
    end

    test "returns :modified for sudo commands" do
      [suggestion | _] = Correction.suggest("sudo rm file.txt", %{})
      assert suggestion.risk_level == :high
      assert suggestion.requires_gate == true
    end
  end

  describe "validate_suggestion/1" do
    test "validates safe suggestion" do
      {:ok, suggestion} =
        Suggestion.new(%{
          original_command: "ls",
          suggested_command: "ls -la",
          risk_level: :none,
          reason: "test",
          requires_gate: false,
          correction_type: :safe
        })

      assert {:ok, ^suggestion} = Correction.validate_suggestion(suggestion)
    end

    test "validates suggestion with nil suggested_command" do
      {:ok, suggestion} =
        Suggestion.new(%{
          original_command: "rm -rf /",
          risk_level: :critical,
          reason: "test",
          requires_gate: true,
          correction_type: :blocked
        })

      assert {:ok, ^suggestion} = Correction.validate_suggestion(suggestion)
    end

    test "rejects suggestion that is more dangerous than original" do
      {:ok, suggestion} =
        Suggestion.new(%{
          original_command: "echo hello",
          suggested_command: "rm -rf /",
          risk_level: :none,
          reason: "test",
          requires_gate: false,
          correction_type: :safe
        })

      assert {:error, _} = Correction.validate_suggestion(suggestion)
    end
  end
end
