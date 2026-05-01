defmodule Tet.Runtime.Remote.CapabilitiesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Runtime.Remote.Capabilities

  describe "kinds/0" do
    test "returns all supported capability kinds including :streaming" do
      kinds = Capabilities.kinds()

      assert :commands in kinds
      assert :verifiers in kinds
      assert :artifacts in kinds
      assert :cancel in kinds
      assert :heartbeat in kinds
      assert :streaming in kinds
    end

    test "returns kinds in stable order" do
      assert Capabilities.kinds() == [
               :commands,
               :verifiers,
               :artifacts,
               :cancel,
               :heartbeat,
               :streaming
             ]
    end
  end

  describe "normalize/1" do
    test "normalizes streaming capabilities" do
      assert {:ok, caps} = Capabilities.normalize(%{streaming: true})
      assert caps.streaming == %{enabled: true}
    end

    test "normalizes streaming as disabled by default" do
      assert {:ok, caps} = Capabilities.normalize(%{})
      assert caps.streaming == %{enabled: false}
    end

    test "normalizes map with all capability kinds" do
      input = %{
        commands: ["build", "test"],
        verifiers: ["format"],
        artifacts: true,
        cancel: true,
        heartbeat: true,
        streaming: true
      }

      assert {:ok, caps} = Capabilities.normalize(input)
      assert caps.commands == %{enabled: true, entries: ["build", "test"]}
      assert caps.verifiers == %{enabled: true, entries: ["format"]}
      assert caps.artifacts == %{enabled: true}
      assert caps.cancel == %{enabled: true}
      assert caps.heartbeat == %{enabled: true}
      assert caps.streaming == %{enabled: true}
    end

    test "normalizes list of capabilities" do
      assert {:ok, caps} = Capabilities.normalize([:commands, :artifacts])
      assert caps.commands == %{enabled: true, entries: []}
      assert caps.artifacts == %{enabled: true}
    end

    test "normalizes string capability keys" do
      assert {:ok, caps} = Capabilities.normalize(%{"streaming" => true})
      assert caps.streaming == %{enabled: true}
    end

    test "returns error for unknown capability kind (atom)" do
      assert {:error, {:unknown_remote_capability, :quantum_computing}} =
               Capabilities.normalize(%{quantum_computing: true})
    end

    test "returns error for unknown capability kind (string)" do
      assert {:error, {:unknown_remote_capability, "quantum_computing"}} =
               Capabilities.normalize(%{"quantum_computing" => true})
    end

    test "returns error for non-map/non-list input" do
      assert {:error, {:invalid_remote_capabilities, :not_a_map_or_list}} =
               Capabilities.normalize("invalid")
    end
  end

  describe "require_enabled/2" do
    test "returns :ok when capability is enabled" do
      assert {:ok, caps} = Capabilities.normalize(%{streaming: true})
      assert Capabilities.require_enabled(caps, :streaming) == :ok
    end

    test "returns error when capability is disabled" do
      assert {:ok, caps} = Capabilities.normalize(%{streaming: false})

      assert {:error, {:missing_remote_capability, :streaming}} =
               Capabilities.require_enabled(caps, :streaming)
    end
  end
end
