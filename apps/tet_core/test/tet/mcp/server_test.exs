defmodule Tet.Mcp.ServerTest do
  use ExUnit.Case, async: true

  alias Tet.Mcp.Server

  describe "new/1" do
    test "creates a server with required fields" do
      assert {:ok, server} = Server.new(%{id: "fs", command: "mcp-filesystem"})
      assert server.id == "fs"
      assert server.command == "mcp-filesystem"
    end

    test "creates a server with all optional fields" do
      assert {:ok, server} =
               Server.new(%{
                 id: "git",
                 command: "mcp-git",
                 args: ["--repo", "/tmp"],
                 env: %{"GIT_DIR" => "/tmp"},
                 enabled: false,
                 health_check_interval: 60_000,
                 status: :stopped
               })

      assert server.args == ["--repo", "/tmp"]
      assert server.env == %{"GIT_DIR" => "/tmp"}
      assert server.enabled == false
      assert server.health_check_interval == 60_000
      assert server.status == :stopped
    end

    test "defaults enabled to true" do
      assert {:ok, server} = Server.new(%{id: "fs", command: "mcp-fs"})
      assert server.enabled == true
    end

    test "defaults status to :unknown" do
      assert {:ok, server} = Server.new(%{id: "fs", command: "mcp-fs"})
      assert server.status == :unknown
    end

    test "defaults args to empty list" do
      assert {:ok, server} = Server.new(%{id: "fs", command: "mcp-fs"})
      assert server.args == []
    end

    test "defaults env to empty map" do
      assert {:ok, server} = Server.new(%{id: "fs", command: "mcp-fs"})
      assert server.env == %{}
    end

    test "defaults health_check_interval to 30_000" do
      assert {:ok, server} = Server.new(%{id: "fs", command: "mcp-fs"})
      assert server.health_check_interval == 30_000
    end

    test "accepts string keys" do
      assert {:ok, server} = Server.new(%{"id" => "fs", "command" => "mcp-fs"})
      assert server.id == "fs"
    end

    test "rejects missing id" do
      assert {:error, :missing_id} = Server.new(%{command: "mcp-fs"})
    end

    test "rejects empty id" do
      assert {:error, :missing_id} = Server.new(%{id: "", command: "mcp-fs"})
    end

    test "rejects invalid id with slashes" do
      assert {:error, :invalid_id} = Server.new(%{id: "a/b", command: "mcp-fs"})
    end

    test "rejects invalid id with dots" do
      assert {:error, :invalid_id} = Server.new(%{id: "..", command: "mcp-fs"})
    end

    test "rejects empty command" do
      assert {:error, {:invalid_command, ""}} = Server.new(%{id: "fs", command: ""})
    end

    test "rejects nil command" do
      assert {:error, {:invalid_command, nil}} = Server.new(%{id: "fs", command: nil})
    end

    test "rejects non-map input" do
      assert {:error, :invalid_server_attrs} = Server.new("bad")
    end

    test "rejects invalid args" do
      assert {:error, :invalid_args} = Server.new(%{id: "fs", command: "c", args: "bad"})
    end

    test "rejects args with non-binary elements" do
      assert {:error, :invalid_args} = Server.new(%{id: "fs", command: "c", args: [123, "ok"]})
    end

    test "rejects args containing atoms" do
      assert {:error, :invalid_args} = Server.new(%{id: "fs", command: "c", args: [:flag]})
    end

    test "rejects invalid env" do
      assert {:error, :invalid_env} = Server.new(%{id: "fs", command: "c", env: "bad"})
    end

    test "rejects env with non-binary keys" do
      assert {:error, :invalid_env} =
               Server.new(%{id: "fs", command: "c", env: %{atom_key: "val"}})
    end

    test "rejects env with non-binary values" do
      assert {:error, :invalid_env} = Server.new(%{id: "fs", command: "c", env: %{"KEY" => 123}})
    end

    test "rejects invalid enabled" do
      assert {:error, :invalid_enabled} = Server.new(%{id: "fs", command: "c", enabled: "yes"})
    end

    test "rejects negative health_check_interval" do
      assert {:error, :invalid_health_check_interval} =
               Server.new(%{id: "fs", command: "c", health_check_interval: -1})
    end

    test "rejects invalid status" do
      assert {:error, :invalid_status} = Server.new(%{id: "fs", command: "c", status: "alive"})
    end

    test "accepts zero health_check_interval" do
      assert {:ok, server} =
               Server.new(%{id: "fs", command: "c", health_check_interval: 0})

      assert server.health_check_interval == 0
    end
  end

  describe "new!/1" do
    test "returns server on success" do
      server = Server.new!(%{id: "fs", command: "mcp-fs"})
      assert server.id == "fs"
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, ~r/invalid mcp server/, fn ->
        Server.new!(%{id: "", command: "c"})
      end
    end
  end

  describe "startable?/1" do
    test "true when enabled and status is unknown" do
      server = Server.new!(%{id: "fs", command: "c"})
      assert Server.startable?(server) == true
    end

    test "true when enabled and status is stopped" do
      server = Server.new!(%{id: "fs", command: "c", status: :stopped})
      assert Server.startable?(server) == true
    end

    test "true when enabled and status is running" do
      server = Server.new!(%{id: "fs", command: "c", status: :running})
      assert Server.startable?(server) == true
    end

    test "false when disabled" do
      server = Server.new!(%{id: "fs", command: "c", enabled: false})
      assert Server.startable?(server) == false
    end

    test "false when status is error" do
      server = Server.new!(%{id: "fs", command: "c", status: :error})
      assert Server.startable?(server) == false
    end

    test "false when disabled AND error" do
      server = Server.new!(%{id: "fs", command: "c", enabled: false, status: :error})
      assert Server.startable?(server) == false
    end
  end

  describe "status helpers" do
    test "running?/1 returns true for running status" do
      server = Server.new!(%{id: "fs", command: "c", status: :running})
      assert Server.running?(server) == true
    end

    test "running?/1 returns false for other statuses" do
      for status <- [:unknown, :stopped, :error] do
        server = Server.new!(%{id: "fs", command: "c", status: status})
        assert Server.running?(server) == false
      end
    end

    test "enabled?/1 returns true for enabled server" do
      server = Server.new!(%{id: "fs", command: "c"})
      assert Server.enabled?(server) == true
    end

    test "enabled?/1 returns false for disabled server" do
      server = Server.new!(%{id: "fs", command: "c", enabled: false})
      assert Server.enabled?(server) == false
    end
  end

  describe "mark_* helpers" do
    test "mark_running/1 sets status and heartbeat" do
      server = Server.new!(%{id: "fs", command: "c"})
      marked = Server.mark_running(server)
      assert marked.status == :running
      assert %DateTime{} = marked.last_heartbeat
    end

    test "mark_stopped/1 sets status to stopped" do
      server = Server.new!(%{id: "fs", command: "c", status: :running})
      marked = Server.mark_stopped(server)
      assert marked.status == :stopped
    end

    test "mark_error/1 sets status to error" do
      server = Server.new!(%{id: "fs", command: "c"})
      marked = Server.mark_error(server)
      assert marked.status == :error
    end
  end

  describe "heartbeat/1" do
    test "updates last_heartbeat for running server" do
      server = Server.new!(%{id: "fs", command: "c", status: :running, last_heartbeat: nil})
      heartbeated = Server.heartbeat(server)
      assert %DateTime{} = heartbeated.last_heartbeat
    end

    test "no-op for non-running server" do
      server = Server.new!(%{id: "fs", command: "c", status: :stopped})
      heartbeated = Server.heartbeat(server)
      assert heartbeated.last_heartbeat == nil
    end
  end

  describe "to_map/1" do
    test "serializes server to string-keyed map" do
      server = Server.new!(%{id: "fs", command: "mcp-fs", args: ["/tmp"]})
      map = Server.to_map(server)

      assert map["id"] == "fs"
      assert map["command"] == "mcp-fs"
      assert map["args"] == ["/tmp"]
      assert map["enabled"] == true
      assert map["status"] == "unknown"
      assert map["last_heartbeat"] == nil
    end

    test "serializes heartbeat as ISO8601" do
      server = Server.new!(%{id: "fs", command: "c"}) |> Server.mark_running()
      map = Server.to_map(server)

      assert is_binary(map["last_heartbeat"])
      # ISO8601 format check
      assert String.match?(map["last_heartbeat"], ~r/^\d{4}-\d{2}-\d{2}/)
    end
  end

  describe "statuses/0" do
    test "returns all four status atoms" do
      assert :unknown in Server.statuses()
      assert :running in Server.statuses()
      assert :stopped in Server.statuses()
      assert :error in Server.statuses()
    end
  end
end
