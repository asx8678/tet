defmodule Tet.Mcp.RegistryTest do
  use ExUnit.Case, async: false

  alias Tet.Mcp.Registry
  alias Tet.Mcp.Server

  setup do
    name = :"mcp_registry_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: name)
    {:ok, server: name}
  end

  defp new_server(id, opts \\ []) do
    defaults = %{id: id, command: "mcp-#{id}"}
    attrs = Enum.into(opts, defaults)
    Server.new!(attrs)
  end

  describe "register/2" do
    test "registers a server", %{server: srv} do
      server = new_server("fs")
      assert :ok = Registry.register(server, server: srv)
      assert {:ok, ^server} = Registry.lookup("fs", server: srv)
    end

    test "replaces existing server with same id", %{server: srv} do
      s1 = new_server("fs", command: "mcp-fs-v1")
      s2 = new_server("fs", command: "mcp-fs-v2")
      Registry.register(s1, server: srv)
      Registry.register(s2, server: srv)

      assert {:ok, found} = Registry.lookup("fs", server: srv)
      assert found.command == "mcp-fs-v2"
    end
  end

  describe "unregister/2" do
    test "removes a registered server", %{server: srv} do
      Registry.register(new_server("fs"), server: srv)
      assert :ok = Registry.unregister("fs", server: srv)
      assert {:error, :not_found} = Registry.lookup("fs", server: srv)
    end

    test "returns error for unknown id", %{server: srv} do
      assert {:error, :not_found} = Registry.unregister("nope", server: srv)
    end
  end

  describe "update/3" do
    test "updates specific fields", %{server: srv} do
      Registry.register(new_server("fs", command: "mcp-fs-v1"), server: srv)
      {:ok, updated} = Registry.update("fs", %{command: "mcp-fs-v2"}, server: srv)
      assert updated.command == "mcp-fs-v2"
    end

    test "updates enabled field", %{server: srv} do
      Registry.register(new_server("fs"), server: srv)
      {:ok, updated} = Registry.update("fs", %{enabled: false}, server: srv)
      assert updated.enabled == false
    end

    test "preserves non-updated fields", %{server: srv} do
      Registry.register(new_server("fs", args: ["/tmp"]), server: srv)
      {:ok, _updated} = Registry.update("fs", %{command: "new-cmd"}, server: srv)
      {:ok, found} = Registry.lookup("fs", server: srv)
      assert found.args == ["/tmp"]
      assert found.command == "new-cmd"
    end

    test "returns error for unknown id", %{server: srv} do
      assert {:error, :not_found} = Registry.update("nope", %{command: "x"}, server: srv)
    end

    test "rejects invalid command via Server.new validation", %{server: srv} do
      Registry.register(new_server("fs"), server: srv)

      assert {:error, {:invalid_command, ""}} =
               Registry.update("fs", %{command: ""}, server: srv)
    end

    test "rejects invalid args via Server.new validation", %{server: srv} do
      Registry.register(new_server("fs"), server: srv)

      assert {:error, :invalid_args} =
               Registry.update("fs", %{args: [123]}, server: srv)
    end

    test "preserves runtime status and heartbeat through update", %{server: srv} do
      server = new_server("fs") |> Server.mark_running()
      Registry.register(server, server: srv)
      {:ok, updated} = Registry.update("fs", %{command: "new-cmd"}, server: srv)
      assert updated.status == :running
      assert updated.last_heartbeat != nil
      assert updated.command == "new-cmd"
    end

    test "accepts string keys in updates", %{server: srv} do
      Registry.register(new_server("fs"), server: srv)
      {:ok, updated} = Registry.update("fs", %{"command" => "new-cmd"}, server: srv)
      assert updated.command == "new-cmd"
    end
  end

  describe "lookup/2" do
    test "returns registered server", %{server: srv} do
      server = new_server("git")
      Registry.register(server, server: srv)
      assert {:ok, ^server} = Registry.lookup("git", server: srv)
    end

    test "returns error for unknown id", %{server: srv} do
      assert {:error, :not_found} = Registry.lookup("nope", server: srv)
    end
  end

  describe "list_all/1" do
    test "returns all registered servers", %{server: srv} do
      Registry.register(new_server("a"), server: srv)
      Registry.register(new_server("b"), server: srv)
      all = Registry.list_all(server: srv)
      ids = Enum.map(all, & &1.id) |> Enum.sort()
      assert ids == ["a", "b"]
    end

    test "returns empty list when nothing registered", %{server: srv} do
      assert [] = Registry.list_all(server: srv)
    end
  end

  describe "list_startable/1" do
    test "returns only enabled, non-error servers", %{server: srv} do
      s1 = new_server("startable", enabled: true)
      s2 = new_server("disabled", enabled: false)
      s3 = new_server("errored", status: :error)

      Registry.register(s1, server: srv)
      Registry.register(s2, server: srv)
      Registry.register(s3, server: srv)

      startable = Registry.list_startable(server: srv)
      ids = Enum.map(startable, & &1.id)
      assert ids == ["startable"]
    end
  end

  describe "list_running/1" do
    test "returns only running servers", %{server: srv} do
      s1 = new_server("running", status: :running)
      s2 = new_server("stopped", status: :stopped)

      Registry.register(s1, server: srv)
      Registry.register(s2, server: srv)

      running = Registry.list_running(server: srv)
      assert [%{id: "running"}] = running
    end
  end

  describe "update_health/3" do
    test "marks server as running", %{server: srv} do
      Registry.register(new_server("fs"), server: srv)
      {:ok, updated} = Registry.update_health("fs", :running, server: srv)
      assert updated.status == :running
      assert updated.last_heartbeat != nil
    end

    test "marks server as error", %{server: srv} do
      Registry.register(new_server("fs"), server: srv)
      {:ok, updated} = Registry.update_health("fs", :error, server: srv)
      assert updated.status == :error
    end

    test "marks server as stopped", %{server: srv} do
      Registry.register(new_server("fs"), server: srv)
      {:ok, updated} = Registry.update_health("fs", :stopped, server: srv)
      assert updated.status == :stopped
    end

    test "returns error for unknown id", %{server: srv} do
      assert {:error, :not_found} = Registry.update_health("nope", :running, server: srv)
    end

    test "returns error for invalid status", %{server: srv} do
      Registry.register(new_server("fs"), server: srv)

      assert {:error, {:invalid_status, :nonexistent}} =
               Registry.update_health("fs", :nonexistent, server: srv)
    end

    test "does not crash Registry on invalid status", %{server: srv} do
      Registry.register(new_server("fs"), server: srv)
      # The Registry should still work after an invalid status attempt
      assert {:error, {:invalid_status, :bad}} =
               Registry.update_health("fs", :bad, server: srv)

      assert {:ok, _} = Registry.lookup("fs", server: srv)
    end
  end

  describe "heartbeat/2" do
    test "updates heartbeat for running server", %{server: srv} do
      server = new_server("fs", status: :running) |> Server.mark_running()
      Registry.register(server, server: srv)

      {:ok, updated} = Registry.heartbeat("fs", server: srv)
      assert updated.last_heartbeat != nil
    end

    test "returns error for unknown id", %{server: srv} do
      assert {:error, :not_found} = Registry.heartbeat("nope", server: srv)
    end
  end

  describe "sync_config/2" do
    test "adds new servers from config", %{server: srv} do
      configs = [%{id: "new-srv", command: "mcp-new"}]
      :ok = Registry.sync_config(configs, server: srv)

      assert {:ok, server} = Registry.lookup("new-srv", server: srv)
      assert server.id == "new-srv"
    end

    test "updates existing servers, preserving health", %{server: srv} do
      existing = new_server("fs", command: "v1") |> Server.mark_running()
      Registry.register(existing, server: srv)

      :ok = Registry.sync_config([%{id: "fs", command: "v2"}], server: srv)

      {:ok, updated} = Registry.lookup("fs", server: srv)
      # Command updated from config
      assert updated.command == "v2"
      # Status preserved from existing
      assert updated.status == :running
    end

    test "removes servers not in config", %{server: srv} do
      Registry.register(new_server("orphan"), server: srv)

      :ok = Registry.sync_config([%{id: "other", command: "c"}], server: srv)

      assert {:error, :not_found} = Registry.lookup("orphan", server: srv)
      assert {:ok, _} = Registry.lookup("other", server: srv)
    end

    test "rejects sync when any config is invalid", %{server: srv} do
      configs = [
        %{id: "valid", command: "mcp-valid"},
        %{id: "", command: "invalid-missing-id"},
        %{id: "no-cmd"}
      ]

      assert {:error, errors} = Registry.sync_config(configs, server: srv)
      assert length(errors) == 2
      # The valid one should NOT have been registered — Registry unchanged
      assert {:error, :not_found} = Registry.lookup("valid", server: srv)
    end

    test "accepts Server structs in config", %{server: srv} do
      server = Server.new!(%{id: "struct", command: "mcp-struct"})
      :ok = Registry.sync_config([server], server: srv)
      assert {:ok, _} = Registry.lookup("struct", server: srv)
    end

    test "empty config removes all servers", %{server: srv} do
      Registry.register(new_server("a"), server: srv)
      Registry.register(new_server("b"), server: srv)

      :ok = Registry.sync_config([], server: srv)
      assert Registry.list_all(server: srv) == []
    end

    test "preserves existing servers when invalid config is provided", %{server: srv} do
      Registry.register(new_server("existing"), server: srv)

      configs = [%{id: "bad", command: ""}]
      assert {:error, _errors} = Registry.sync_config(configs, server: srv)

      # Existing server should still be there
      assert {:ok, _} = Registry.lookup("existing", server: srv)
    end
  end

  describe "count/1" do
    test "returns number of registered servers", %{server: srv} do
      assert Registry.count(server: srv) == 0
      Registry.register(new_server("a"), server: srv)
      assert Registry.count(server: srv) == 1
      Registry.register(new_server("b"), server: srv)
      assert Registry.count(server: srv) == 2
      Registry.unregister("a", server: srv)
      assert Registry.count(server: srv) == 1
    end
  end
end
