defmodule Tet.Plugin.CapabilityTest do
  use ExUnit.Case, async: true

  alias Tet.Plugin.{Capability, Manifest}

  describe "known_capabilities/0" do
    test "returns the closed set of capability atoms" do
      caps = Capability.known_capabilities()

      assert :tool_execution in caps
      assert :file_access in caps
      assert :network in caps
      assert :shell in caps
      assert :mcp in caps
      assert length(caps) == 5
    end
  end

  describe "trust_ceiling/1" do
    test "sandboxed allows only tool_execution" do
      assert Capability.trust_ceiling(:sandboxed) == [:tool_execution]
    end

    test "restricted allows tool_execution, file_access, mcp" do
      assert Capability.trust_ceiling(:restricted) == [:tool_execution, :file_access, :mcp]
    end

    test "full allows all known capabilities" do
      assert Capability.trust_ceiling(:full) == Capability.known_capabilities()
    end
  end

  describe "authorized?/2" do
    test "returns true when capability is declared and within trust ceiling" do
      manifest =
        Manifest.new!(%{
          name: "demo",
          version: "1.0.0",
          capabilities: [:tool_execution],
          trust_level: :sandboxed,
          entrypoint: Demo
        })

      assert Capability.authorized?(manifest, :tool_execution)
    end

    test "returns false when capability is not declared" do
      manifest =
        Manifest.new!(%{
          name: "demo",
          version: "1.0.0",
          capabilities: [:tool_execution],
          trust_level: :sandboxed,
          entrypoint: Demo
        })

      refute Capability.authorized?(manifest, :file_access)
    end

    test "returns false when capability exceeds trust ceiling" do
      # This manifest would fail validation, but authorized? still works structurally
      manifest = %Manifest{
        name: "leaky",
        version: "1.0.0",
        capabilities: [:tool_execution, :shell],
        trust_level: :sandboxed,
        entrypoint: Demo
      }

      assert Capability.authorized?(manifest, :tool_execution)
      refute Capability.authorized?(manifest, :shell)
    end
  end

  describe "gate/3" do
    test "executes function when authorized" do
      manifest =
        Manifest.new!(%{
          name: "demo",
          version: "1.0.0",
          capabilities: [:tool_execution],
          trust_level: :sandboxed,
          entrypoint: Demo
        })

      assert Capability.gate(manifest, :tool_execution, fn -> :ok end) == :ok
    end

    test "returns error when unauthorized" do
      manifest =
        Manifest.new!(%{
          name: "demo",
          version: "1.0.0",
          capabilities: [:tool_execution],
          trust_level: :sandboxed,
          entrypoint: Demo
        })

      assert Capability.gate(manifest, :shell, fn -> :boom end) ==
               {:error, {:unauthorized_capability, :shell}}
    end

    test "does not execute function when unauthorized" do
      manifest =
        Manifest.new!(%{
          name: "demo",
          version: "1.0.0",
          capabilities: [:tool_execution],
          trust_level: :sandboxed,
          entrypoint: Demo
        })

      # Side-effect proof: the function never runs
      ref = make_ref()
      _ = Capability.gate(manifest, :network, fn -> send(self(), ref) end)
      refute_received ^ref
    end

    test "full trust plugin can gate any declared capability" do
      manifest =
        Manifest.new!(%{
          name: "all-the-things",
          version: "1.0.0",
          capabilities: [:tool_execution, :file_access, :network, :shell, :mcp],
          trust_level: :full,
          entrypoint: Demo
        })

      for cap <- Capability.known_capabilities() do
        assert Capability.gate(manifest, cap, fn -> :granted end) == :granted
      end
    end
  end

  describe "validate_for_trust/2" do
    test "returns :ok when all capabilities are within trust ceiling" do
      assert Capability.validate_for_trust([:tool_execution], :sandboxed) == :ok
      assert Capability.validate_for_trust([:tool_execution, :file_access], :restricted) == :ok
      assert Capability.validate_for_trust(Capability.known_capabilities(), :full) == :ok
    end

    test "returns error listing overflow capabilities" do
      assert {:error, {:exceeds_trust, [:shell]}} =
               Capability.validate_for_trust([:shell], :sandboxed)

      assert {:error, {:exceeds_trust, overflow}} =
               Capability.validate_for_trust([:network, :shell], :restricted)

      assert :network in overflow
      assert :shell in overflow
    end

    test "empty capability list always passes" do
      assert Capability.validate_for_trust([], :sandboxed) == :ok
    end
  end
end
