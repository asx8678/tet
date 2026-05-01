defmodule Tet.Runtime.Mcp.SupervisorTest do
  use ExUnit.Case, async: false

  alias Tet.Mcp.Server
  alias Tet.Runtime.Mcp.Supervisor

  setup do
    # Start a BEAM Registry for worker :via tuples (if not already running)
    unless Process.whereis(Tet.Runtime.Mcp.ProcessRegistry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Tet.Runtime.Mcp.ProcessRegistry)
    end

    # Start a unique Tet.Mcp.Registry per test for config
    reg_name = :"mcp_config_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Tet.Mcp.Registry.start_link(name: reg_name)

    # Start the DynamicSupervisor (if not already in app tree)
    unless Process.whereis(Supervisor.name()) do
      {:ok, _pid} = Supervisor.start_link([])
    end

    # Clean up any leftover servers from prior test runs
    for %{id: id} <- Supervisor.list_servers() do
      Supervisor.stop_server(id, registry: reg_name)
    end

    {:ok, registry: reg_name}
  end

  defp register_server(registry, id, opts \\ []) do
    defaults = %{id: id, command: "mcp-#{id}"}
    attrs = Enum.into(opts, defaults)
    server = Server.new!(attrs)
    :ok = Tet.Mcp.Registry.register(server, server: registry)
    server
  end

  describe "start_server/2" do
    test "starts a registered, enabled server", %{registry: reg} do
      register_server(reg, "fs")
      assert {:ok, _pid} = Supervisor.start_server("fs", registry: reg)

      servers = Supervisor.list_servers()
      assert Enum.any?(servers, &(&1.id == "fs"))
    after
      Supervisor.stop_server("fs", registry: reg)
    end

    test "returns error for unregistered server", %{registry: reg} do
      assert {:error, :not_found} = Supervisor.start_server("nope", registry: reg)
    end

    test "returns error for disabled server", %{registry: reg} do
      register_server(reg, "disabled", enabled: false)
      assert {:error, :not_startable} = Supervisor.start_server("disabled", registry: reg)
    end

    test "returns error for errored server", %{registry: reg} do
      register_server(reg, "errored", status: :error)
      assert {:error, :not_startable} = Supervisor.start_server("errored", registry: reg)
    end

    test "returns :already_started for duplicate start", %{registry: reg} do
      register_server(reg, "dup")
      assert {:ok, _} = Supervisor.start_server("dup", registry: reg)
      assert {:error, :already_started} = Supervisor.start_server("dup", registry: reg)
    after
      Supervisor.stop_server("dup", registry: reg)
    end

    test "updates registry health to running on start", %{registry: reg} do
      register_server(reg, "health-check")
      Supervisor.start_server("health-check", registry: reg)

      {:ok, server} = Tet.Mcp.Registry.lookup("health-check", server: reg)
      assert server.status == :running
    after
      Supervisor.stop_server("health-check", registry: reg)
    end
  end

  describe "stop_server/2" do
    test "stops a running server", %{registry: reg} do
      register_server(reg, "stop-me")
      Supervisor.start_server("stop-me", registry: reg)

      assert :ok = Supervisor.stop_server("stop-me", registry: reg)
      servers = Supervisor.list_servers()
      refute Enum.any?(servers, &(&1.id == "stop-me"))
    end

    test "returns error for unknown server", %{registry: reg} do
      assert {:error, :not_found} = Supervisor.stop_server("nope", registry: reg)
    end

    test "updates registry health to stopped", %{registry: reg} do
      register_server(reg, "stop-health")
      Supervisor.start_server("stop-health", registry: reg)
      Supervisor.stop_server("stop-health", registry: reg)

      {:ok, server} = Tet.Mcp.Registry.lookup("stop-health", server: reg)
      assert server.status == :stopped
    end
  end

  describe "reload_server/2" do
    test "stops and restarts a server", %{registry: reg} do
      register_server(reg, "reload-me")
      {:ok, pid1} = Supervisor.start_server("reload-me", registry: reg)

      assert {:ok, pid2} = Supervisor.reload_server("reload-me", registry: reg)
      # New pid after reload
      assert pid1 != pid2
    after
      Supervisor.stop_server("reload-me", registry: reg)
    end

    test "recovers from error state via reload", %{registry: reg} do
      register_server(reg, "recover")
      # Mark as errored
      {:ok, _} = Tet.Mcp.Registry.update_health("recover", :error, server: reg)

      # Reload should reset status and start
      assert {:ok, _pid} = Supervisor.reload_server("recover", registry: reg)

      {:ok, server} = Tet.Mcp.Registry.lookup("recover", server: reg)
      assert server.status == :running
    after
      Supervisor.stop_server("recover", registry: reg)
    end

    test "returns error for unregistered server on reload", %{registry: reg} do
      assert {:error, :not_found} = Supervisor.reload_server("nope", registry: reg)
    end
  end

  describe "start_all/1" do
    test "starts all startable servers", %{registry: reg} do
      register_server(reg, "s1")
      register_server(reg, "s2")
      register_server(reg, "s3-disabled", enabled: false)

      results = Supervisor.start_all(registry: reg)

      # Two should start, one is disabled
      started_count =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      assert started_count == 2
    after
      for id <- ["s1", "s2"] do
        Supervisor.stop_server(id, registry: reg)
      end
    end
  end

  describe "list_servers/0" do
    test "returns running servers with ids and pids", %{registry: reg} do
      register_server(reg, "list-a")
      register_server(reg, "list-b")
      Supervisor.start_server("list-a", registry: reg)
      Supervisor.start_server("list-b", registry: reg)

      servers = Supervisor.list_servers()
      ids = Enum.map(servers, & &1.id) |> Enum.sort()
      assert ids == ["list-a", "list-b"]

      for s <- servers do
        assert is_pid(s.pid)
      end
    after
      for id <- ["list-a", "list-b"] do
        Supervisor.stop_server(id, registry: reg)
      end
    end
  end

  describe "status/1" do
    test "returns correct status counts", %{registry: reg} do
      register_server(reg, "enabled-srv")
      register_server(reg, "disabled-srv", enabled: false)
      Tet.Mcp.Registry.update_health("disabled-srv", :error, server: reg)

      status = Supervisor.status(registry: reg)
      assert status.total == 2
      assert status.enabled == 1
      assert status.running == 0
      assert status.errored == 1
    end
  end

  describe "gate conditions — only enabled and healthy servers start" do
    test "disabled server cannot be started even with good status", %{registry: reg} do
      register_server(reg, "disabled-good", enabled: false, status: :unknown)
      assert {:error, :not_startable} = Supervisor.start_server("disabled-good", registry: reg)
    end

    test "errored server cannot be started even if enabled", %{registry: reg} do
      register_server(reg, "error-enabled", enabled: true, status: :error)
      assert {:error, :not_startable} = Supervisor.start_server("error-enabled", registry: reg)
    end

    test "stopped server can be restarted", %{registry: reg} do
      register_server(reg, "restartable", status: :stopped)
      assert {:ok, _pid} = Supervisor.start_server("restartable", registry: reg)
    after
      Supervisor.stop_server("restartable", registry: reg)
    end

    test "unknown status server can be started", %{registry: reg} do
      register_server(reg, "fresh")
      assert {:ok, _pid} = Supervisor.start_server("fresh", registry: reg)
    after
      Supervisor.stop_server("fresh", registry: reg)
    end
  end
end
