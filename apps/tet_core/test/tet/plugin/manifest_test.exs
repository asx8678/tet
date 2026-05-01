defmodule Tet.Plugin.ManifestTest do
  use ExUnit.Case, async: true

  alias Tet.Plugin.Manifest

  describe "new/1" do
    test "builds a valid manifest with atom keys" do
      assert {:ok, manifest} =
               Manifest.new(%{
                 name: "my-plugin",
                 version: "1.0.0",
                 description: "A test plugin",
                 author: "Alice",
                 capabilities: [:tool_execution],
                 trust_level: :sandboxed,
                 entrypoint: MyPlugin
               })

      assert manifest.name == "my-plugin"
      assert manifest.version == "1.0.0"
      assert manifest.description == "A test plugin"
      assert manifest.author == "Alice"
      assert manifest.capabilities == [:tool_execution]
      assert manifest.trust_level == :sandboxed
      assert manifest.entrypoint == MyPlugin
    end

    test "builds a valid manifest with string keys" do
      assert {:ok, manifest} =
               Manifest.new(%{
                 "name" => "str-plugin",
                 "version" => "2.0.0",
                 "capabilities" => [:tool_execution, :file_access],
                 "trust_level" => :restricted,
                 "entrypoint" => StrPlugin
               })

      assert manifest.name == "str-plugin"
      assert manifest.capabilities == [:tool_execution, :file_access]
    end

    test "description and author are optional" do
      assert {:ok, manifest} =
               Manifest.new(%{
                 name: "minimal",
                 version: "0.1.0",
                 capabilities: [:tool_execution],
                 trust_level: :sandboxed,
                 entrypoint: MinimalPlugin
               })

      assert manifest.description == nil
      assert manifest.author == nil
    end

    test "empty string description becomes nil" do
      assert {:ok, manifest} =
               Manifest.new(%{
                 name: "empty-desc",
                 version: "0.1.0",
                 description: "",
                 capabilities: [:tool_execution],
                 trust_level: :sandboxed,
                 entrypoint: EmptyDescPlugin
               })

      assert manifest.description == nil
    end

    test "rejects missing name" do
      assert {:error, :invalid_name} =
               Manifest.new(%{
                 version: "1.0.0",
                 capabilities: [:tool_execution],
                 trust_level: :sandboxed,
                 entrypoint: NoName
               })
    end

    test "rejects empty name" do
      assert {:error, :invalid_name} =
               Manifest.new(%{
                 name: "",
                 version: "1.0.0",
                 capabilities: [:tool_execution],
                 trust_level: :sandboxed,
                 entrypoint: EmptyName
               })
    end

    test "rejects missing version" do
      assert {:error, :invalid_version} =
               Manifest.new(%{
                 name: "no-ver",
                 capabilities: [:tool_execution],
                 trust_level: :sandboxed,
                 entrypoint: NoVer
               })
    end

    test "rejects invalid trust level" do
      assert {:error, :invalid_trust_level} =
               Manifest.new(%{
                 name: "bad-trust",
                 version: "1.0.0",
                 capabilities: [:tool_execution],
                 trust_level: :omnipotent,
                 entrypoint: BadTrust
               })
    end

    test "rejects non-atom entrypoint" do
      assert {:error, :invalid_entrypoint} =
               Manifest.new(%{
                 name: "bad-entry",
                 version: "1.0.0",
                 capabilities: [:tool_execution],
                 trust_level: :sandboxed,
                 entrypoint: "not_a_module"
               })
    end

    test "rejects unknown capability" do
      assert {:error, {:unknown_capabilities, [:telekinesis]}} =
               Manifest.new(%{
                 name: "magic",
                 version: "1.0.0",
                 capabilities: [:telekinesis],
                 trust_level: :full,
                 entrypoint: MagicPlugin
               })
    end

    test "rejects capabilities exceeding trust level" do
      assert {:error, {:exceeds_trust, [:shell]}} =
               Manifest.new(%{
                 name: "leaky",
                 version: "1.0.0",
                 capabilities: [:tool_execution, :shell],
                 trust_level: :sandboxed,
                 entrypoint: LeakyPlugin
               })
    end

    test "rejects non-list capabilities" do
      assert {:error, :invalid_capabilities} =
               Manifest.new(%{
                 name: "bad-caps",
                 version: "1.0.0",
                 capabilities: "all",
                 trust_level: :full,
                 entrypoint: BadCaps
               })
    end
  end

  describe "new!/1" do
    test "returns manifest on success" do
      manifest =
        Manifest.new!(%{
          name: "bang",
          version: "1.0.0",
          capabilities: [:tool_execution],
          trust_level: :sandboxed,
          entrypoint: BangPlugin
        })

      assert %Manifest{} = manifest
    end

    test "raises on invalid attrs" do
      assert_raise ArgumentError, fn ->
        Manifest.new!(%{
          name: "",
          version: "1.0.0",
          capabilities: [:tool_execution],
          trust_level: :sandboxed,
          entrypoint: BadPlugin
        })
      end
    end
  end

  describe "to_map/1" do
    test "serializes manifest to string-keyed map" do
      manifest =
        Manifest.new!(%{
          name: "ser",
          version: "1.0.0",
          description: "Serializable",
          author: "Bob",
          capabilities: [:tool_execution, :file_access],
          trust_level: :restricted,
          entrypoint: SerPlugin
        })

      map = Manifest.to_map(manifest)

      assert map["name"] == "ser"
      assert map["version"] == "1.0.0"
      assert map["description"] == "Serializable"
      assert map["author"] == "Bob"
      assert map["capabilities"] == [:tool_execution, :file_access]
      assert map["trust_level"] == :restricted
      assert map["entrypoint"] == "SerPlugin"
    end

    test "nil fields serialize as nil" do
      manifest =
        Manifest.new!(%{
          name: "bare",
          version: "0.1.0",
          capabilities: [:mcp],
          trust_level: :restricted,
          entrypoint: BarePlugin
        })

      map = Manifest.to_map(manifest)
      assert map["description"] == nil
      assert map["author"] == nil
    end
  end

  describe "from_map/1" do
    test "round-trips through to_map" do
      original =
        Manifest.new!(%{
          name: "round-trip",
          version: "2.0.0",
          description: "Round trip",
          author: "Carol",
          capabilities: [:tool_execution, :network],
          trust_level: :full,
          entrypoint: RoundTripPlugin
        })

      {:ok, restored} = Manifest.from_map(Manifest.to_map(original))

      assert restored.name == original.name
      assert restored.version == original.version
      assert restored.description == original.description
      assert restored.author == original.author
      assert restored.capabilities == original.capabilities
      assert restored.trust_level == original.trust_level
      assert restored.entrypoint == original.entrypoint
    end

    test "coerces string capabilities to atoms" do
      assert {:ok, manifest} =
               Manifest.from_map(%{
                 "name" => "coerce",
                 "version" => "1.0.0",
                 "capabilities" => ["tool_execution", "mcp"],
                 "trust_level" => "restricted",
                 "entrypoint" => "CoercePlugin"
               })

      assert manifest.capabilities == [:tool_execution, :mcp]
      assert manifest.trust_level == :restricted
    end

    test "handles atom-keyed maps" do
      assert {:ok, manifest} =
               Manifest.from_map(%{
                 name: "atom",
                 version: "1.0.0",
                 capabilities: [:file_access],
                 trust_level: :restricted,
                 entrypoint: AtomPlugin
               })

      assert manifest.name == "atom"
    end

    test "returns error for invalid data" do
      assert {:error, :invalid_name} = Manifest.from_map(%{"name" => ""})
    end
  end

  describe "trust_levels/0" do
    test "returns the three trust levels" do
      levels = Manifest.trust_levels()
      assert :sandboxed in levels
      assert :restricted in levels
      assert :full in levels
    end
  end
end
