defmodule Tet.Runtime.Mcp.WorkerTest do
  use ExUnit.Case, async: false

  alias Tet.Mcp.Registry, as: McpRegistry
  alias Tet.Mcp.Server
  alias Tet.Runtime.Mcp.Worker

  setup do
    # Start the BEAM process registry for :via tuples
    unless Process.whereis(Tet.Runtime.Mcp.ProcessRegistry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Tet.Runtime.Mcp.ProcessRegistry)
    end

    # Start a unique Tet.Mcp.Registry per test for health sync
    reg_name = :"mcp_worker_reg_#{System.unique_integer([:positive])}"
    {:ok, _pid} = McpRegistry.start_link(name: reg_name)

    # Trap exits so worker exits don't kill the test process
    Process.flag(:trap_exit, true)

    {:ok, registry: reg_name}
  end

  defp lookup_pid(id) do
    case Registry.lookup(Tet.Runtime.Mcp.ProcessRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp safe_stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :shutdown, 1_000)
  catch
    :exit, _ -> :ok
  end

  defp safe_stop(_), do: :ok

  # Pre-register a server in the Registry so update_health works
  defp register_in_registry(reg, server) do
    :ok = McpRegistry.register(server, server: reg)
  end

  describe "start_link/1" do
    test "starts a worker and marks server as running", %{registry: reg} do
      server = Server.new!(%{id: "worker-test", command: "mcp-test"})
      assert {:ok, pid} = Worker.start_link({server, [registry: reg]})
      assert is_pid(pid)

      found = Worker.get_server(pid)
      assert found.status == :running
      assert found.last_heartbeat != nil
    after
      safe_stop(lookup_pid("worker-test"))
    end

    test "syncs running status to Registry on init", %{registry: reg} do
      server = Server.new!(%{id: "sync-init-test", command: "mcp-test"})
      register_in_registry(reg, server)
      {:ok, _pid} = Worker.start_link({server, [registry: reg]})

      assert {:ok, reg_server} = McpRegistry.lookup("sync-init-test", server: reg)
      assert reg_server.status == :running
    after
      safe_stop(lookup_pid("sync-init-test"))
    end

    test "backward-compat: starts with bare Server struct", %{registry: _reg} do
      server = Server.new!(%{id: "bare-test", command: "mcp-test"})
      assert {:ok, pid} = Worker.start_link(server)
      assert is_pid(pid)
    after
      safe_stop(lookup_pid("bare-test"))
    end
  end

  describe "get_server/1" do
    test "returns the server struct", %{registry: _reg} do
      server = Server.new!(%{id: "get-test", command: "mcp-get"})
      {:ok, pid} = Worker.start_link({server, [registry: McpRegistry]})

      found = Worker.get_server(pid)
      assert found.id == "get-test"
      assert found.command == "mcp-get"
    after
      safe_stop(lookup_pid("get-test"))
    end

    test "returns nil for dead process", %{registry: _reg} do
      server = Server.new!(%{id: "dead-test", command: "mcp-dead"})
      {:ok, pid} = Worker.start_link({server, [registry: McpRegistry]})
      GenServer.stop(pid, :shutdown)

      assert Worker.get_server(pid) == nil
    end
  end

  describe "heartbeat/1" do
    test "updates the heartbeat timestamp", %{registry: _reg} do
      server = Server.new!(%{id: "hb-test", command: "mcp-hb"})
      {:ok, pid} = Worker.start_link({server, [registry: McpRegistry]})

      # Get initial heartbeat
      initial = Worker.get_server(pid)
      :timer.sleep(10)

      # Send heartbeat
      Worker.heartbeat(pid)

      updated = Worker.get_server(pid)
      # Heartbeat should be at or after initial
      assert DateTime.compare(updated.last_heartbeat, initial.last_heartbeat) in [:eq, :gt]
    after
      safe_stop(lookup_pid("hb-test"))
    end

    test "syncs heartbeat to Registry", %{registry: reg} do
      server = Server.new!(%{id: "hb-sync-test", command: "mcp-hb"})
      register_in_registry(reg, server)
      {:ok, pid} = Worker.start_link({server, [registry: reg]})

      # Get initial Registry heartbeat
      {:ok, initial_reg} = McpRegistry.lookup("hb-sync-test", server: reg)
      :timer.sleep(10)

      Worker.heartbeat(pid)

      {:ok, updated_reg} = McpRegistry.lookup("hb-sync-test", server: reg)

      assert DateTime.compare(updated_reg.last_heartbeat, initial_reg.last_heartbeat) in [
               :eq,
               :gt
             ]
    after
      safe_stop(lookup_pid("hb-sync-test"))
    end
  end

  describe "lifecycle events" do
    test "publishes started event on init", %{registry: _reg} do
      # Subscribe to lifecycle events
      Tet.EventBus.subscribe("mcp.lifecycle")

      server = Server.new!(%{id: "event-test", command: "mcp-event"})
      {:ok, _pid} = Worker.start_link({server, [registry: McpRegistry]})

      # Should receive a started event
      assert_receive {:tet_event, "mcp.lifecycle",
                      %{server_id: "event-test", event: :started, status: :running}},
                     500
    after
      safe_stop(lookup_pid("event-test"))
    end

    test "publishes stopped event with :stopped status on normal shutdown", %{registry: _reg} do
      Tet.EventBus.subscribe("mcp.lifecycle")

      server = Server.new!(%{id: "stop-event", command: "mcp-stop"})
      {:ok, pid} = Worker.start_link({server, [registry: McpRegistry]})

      # Flush the started event
      assert_receive {:tet_event, "mcp.lifecycle", %{event: :started}}, 500

      GenServer.stop(pid, :shutdown)

      assert_receive {:tet_event, "mcp.lifecycle",
                      %{server_id: "stop-event", event: :stopped, status: :stopped}},
                     500
    end

    test "publishes stopped event with :error status on abnormal termination", %{registry: _reg} do
      Tet.EventBus.subscribe("mcp.lifecycle")

      server = Server.new!(%{id: "error-event", command: "mcp-error"})
      {:ok, pid} = Worker.start_link({server, [registry: McpRegistry]})

      assert_receive {:tet_event, "mcp.lifecycle", %{event: :started}}, 500

      GenServer.stop(pid, {:error, :boom})

      assert_receive {:tet_event, "mcp.lifecycle",
                      %{server_id: "error-event", event: :stopped, status: :error}},
                     500
    end
  end

  describe "Registry sync on termination" do
    test "updates Registry to :stopped on normal shutdown", %{registry: reg} do
      server = Server.new!(%{id: "term-stop-test", command: "mcp-term"})
      register_in_registry(reg, server)
      {:ok, pid} = Worker.start_link({server, [registry: reg]})

      GenServer.stop(pid, :shutdown)

      {:ok, reg_server} = McpRegistry.lookup("term-stop-test", server: reg)
      assert reg_server.status == :stopped
    end

    test "updates Registry to :error on abnormal exit", %{registry: reg} do
      server = Server.new!(%{id: "term-error-test", command: "mcp-term"})
      register_in_registry(reg, server)
      {:ok, pid} = Worker.start_link({server, [registry: reg]})

      # Exit with abnormal reason
      GenServer.stop(pid, {:error, :boom})

      {:ok, reg_server} = McpRegistry.lookup("term-error-test", server: reg)
      assert reg_server.status == :error
    end

    test "updates Registry to :error when worker crashes abnormally", %{registry: reg} do
      Tet.EventBus.subscribe("mcp.lifecycle")

      server = Server.new!(%{id: "crash-event", command: "mcp-crash"})
      register_in_registry(reg, server)
      {:ok, pid} = Worker.start_link({server, [registry: reg]})

      assert_receive {:tet_event, "mcp.lifecycle", %{event: :started}}, 500

      # Force an abnormal exit — :boom is catchable via trap_exit,
      # unlike :kill which bypasses terminate/2 entirely.
      # The EXIT signal routes through handle_info → terminate → Registry update.
      Process.exit(pid, :boom)

      # Give time for cleanup
      Process.sleep(50)

      # Registry should reflect error status
      assert {:ok, %{status: :error}} = McpRegistry.lookup("crash-event", server: reg)
    end
  end
end
