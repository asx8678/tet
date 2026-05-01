defmodule Tet.Runtime.Plugin.SupervisorTest do
  use ExUnit.Case, async: false

  alias Tet.Plugin.Manifest
  alias Tet.Runtime.Plugin.Supervisor

  # A minimal test plugin module with required callbacks
  defmodule TestPlugin do
    @behaviour Tet.Plugin.Behaviour

    @impl true
    def handle_tool_call(_manifest, _args), do: {:ok, "tool_result"}

    @impl true
    def handle_file_access(_manifest, _args), do: {:ok, "file_result"}
  end

  setup do
    # Ensure the Registry is started (needed by worker :via tuples)
    unless Process.whereis(Tet.Runtime.Plugin.Registry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Tet.Runtime.Plugin.Registry)
    end

    # Ensure the plugin supervisor is alive
    sup_pid =
      case Process.whereis(Supervisor.name()) do
        nil ->
          {:ok, pid} = Supervisor.start_link([])
          pid

        pid ->
          pid
      end

    # Clean up any leftover plugins from prior test runs
    for %{name: name} <- Supervisor.list_plugins() do
      Supervisor.stop_plugin(name)
    end

    {:ok, sup: sup_pid}
  end

  defp valid_manifest(name \\ "test-plugin") do
    Manifest.new!(%{
      name: name,
      version: "1.0.0",
      capabilities: [:tool_execution],
      trust_level: :sandboxed,
      entrypoint: __MODULE__.TestPlugin
    })
  end

  describe "start_plugin/1" do
    test "starts a plugin with a valid manifest" do
      assert {:ok, _pid} = Supervisor.start_plugin(valid_manifest())

      # Verify the plugin appears in list_plugins
      plugins = Supervisor.list_plugins()
      assert Enum.any?(plugins, &(&1.name == "test-plugin"))
    after
      Supervisor.stop_plugin("test-plugin")
    end

    test "returns :already_started for duplicate plugin" do
      assert {:ok, _pid} = Supervisor.start_plugin(valid_manifest("dup-plugin"))
      assert {:error, :already_started} = Supervisor.start_plugin(valid_manifest("dup-plugin"))
    after
      Supervisor.stop_plugin("dup-plugin")
    end
  end

  describe "list_plugins/0" do
    test "returns running plugins" do
      Supervisor.start_plugin(valid_manifest("list-a"))
      Supervisor.start_plugin(valid_manifest("list-b"))

      plugins = Supervisor.list_plugins()
      names = Enum.map(plugins, & &1.name)

      assert "list-a" in names
      assert "list-b" in names
    after
      Supervisor.stop_plugin("list-a")
      Supervisor.stop_plugin("list-b")
    end
  end

  describe "stop_plugin/1" do
    test "stops a running plugin" do
      Supervisor.start_plugin(valid_manifest("stop-me"))

      assert :ok = Supervisor.stop_plugin("stop-me")

      plugins = Supervisor.list_plugins()
      refute Enum.any?(plugins, &(&1.name == "stop-me"))
    end

    test "returns error for unknown plugin" do
      assert {:error, :not_found} = Supervisor.stop_plugin("no-such-plugin")
    end
  end
end
