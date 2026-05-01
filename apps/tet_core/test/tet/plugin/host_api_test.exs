defmodule Tet.Plugin.HostAPITest do
  use ExUnit.Case, async: true

  alias Tet.Plugin.{HostAPI, Manifest}

  # Test plugin module implementing capability callbacks
  defmodule TestPlugin do
    @behaviour Tet.Plugin.Behaviour

    def handle_tool_call(_manifest, _args), do: {:ok, "tool_executed"}
    def handle_file_access(_manifest, _args), do: {:ok, "file_accessed"}
    def handle_shell_command(_manifest, _args), do: {:ok, "shell_executed"}
    def handle_network_request(_manifest, _args), do: {:ok, "network_requested"}
  end

  defp sandboxed_manifest(capabilities) do
    {:ok, m} =
      Manifest.new(%{
        name: "test-plugin",
        version: "1.0.0",
        capabilities: capabilities,
        trust_level: :sandboxed,
        entrypoint: Tet.Plugin.HostAPITest.TestPlugin
      })

    m
  end

  defp full_manifest(capabilities) do
    {:ok, m} =
      Manifest.new(%{
        name: "full-plugin",
        version: "1.0.0",
        capabilities: capabilities,
        trust_level: :full,
        entrypoint: Tet.Plugin.HostAPITest.TestPlugin
      })

    m
  end

  describe "shell_cmd/4" do
    test "executes shell command when authorized" do
      manifest = full_manifest([:shell])

      # HostAPI.shell_cmd calls System.cmd/3 directly when authorized
      {output, exit_code} = HostAPI.shell_cmd(manifest, "echo", ["hello"])
      assert is_binary(output)
      assert exit_code == 0
    end

    test "returns unauthorized error when plugin lacks :shell capability" do
      manifest = sandboxed_manifest([:tool_execution])

      assert {:error, {:unauthorized_capability, :shell}} =
               HostAPI.shell_cmd(manifest, "echo", ["hello"])
    end
  end

  describe "file_write/4" do
    test "writes file when authorized" do
      manifest = full_manifest([:file_access])
      path = Path.join(System.tmp_dir!(), "hostapi_test_#{:erlang.unique_integer()}")

      assert :ok = HostAPI.file_write(manifest, path, "hello world")
      assert File.read!(path) == "hello world"
      File.rm!(path)
    end

    test "returns unauthorized error when plugin lacks :file_access capability" do
      manifest = sandboxed_manifest([:tool_execution])

      assert {:error, {:unauthorized_capability, :file_access}} =
               HostAPI.file_write(manifest, "/tmp/test", "data")
    end
  end

  describe "file_read/3" do
    test "reads file when authorized" do
      manifest = full_manifest([:file_access])
      path = Path.join(System.tmp_dir!(), "hostapi_read_test_#{:erlang.unique_integer()}")
      File.write!(path, "test content")

      assert {:ok, "test content"} = HostAPI.file_read(manifest, path)
      File.rm!(path)
    end

    test "returns unauthorized error when plugin lacks :file_access capability" do
      manifest = sandboxed_manifest([:tool_execution])

      assert {:error, {:unauthorized_capability, :file_access}} =
               HostAPI.file_read(manifest, "/tmp/test")
    end
  end

  describe "execute_tool/2" do
    test "executes tool when authorized" do
      manifest = sandboxed_manifest([:tool_execution])

      assert {:ok, "tool_executed"} = HostAPI.execute_tool(manifest, %{tool: "test"})
    end

    test "returns unauthorized error when plugin lacks :tool_execution capability" do
      manifest = sandboxed_manifest([])

      assert {:error, {:unauthorized_capability, :tool_execution}} =
               HostAPI.execute_tool(manifest, %{tool: "test"})
    end
  end
end
