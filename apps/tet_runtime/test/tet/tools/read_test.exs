defmodule Tet.Runtime.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Tools.Read

  @workspace "/tmp/tet_test_read_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@workspace)
    File.write!(Path.join(@workspace, "hello.txt"), "hello world")
    File.write!(Path.join(@workspace, "multiline.txt"), "line1\nline2\nline3\nline4\nline5")

    long_content = Enum.map(1..100, &"line #{&1}") |> Enum.join("\n")
    File.write!(Path.join(@workspace, "long.txt"), long_content)

    # Binary file
    File.write!(Path.join(@workspace, "binary.bin"), <<0, 1, 2, 3, 4, 5, 0, 255>>)

    on_exit(fn -> File.rm_rf!(@workspace) end)
    %{workspace: @workspace}
  end

  describe "run/2 — basic reading" do
    test "reads an entire small file", %{workspace: ws} do
      result = Read.run(%{"path" => "hello.txt"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.path == "hello.txt"
      assert result.data.content == "hello world"
      assert result.data.total_lines == 1
      assert result.data.binary == false
      assert result.truncated == false
      # BD-0020 envelope keys
      assert result.error == nil
      assert result.correlation == nil
      assert result.redactions == []
    end

    test "reads a multiline file", %{workspace: ws} do
      result = Read.run(%{"path" => "multiline.txt"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.line_count == 5
      assert result.data.total_lines == 5
      assert result.data.content == "line1\nline2\nline3\nline4\nline5"
    end

    test "reads with start_line offset", %{workspace: ws} do
      result = Read.run(%{"path" => "multiline.txt", "start_line" => 3}, workspace_root: ws)

      assert result.ok == true
      assert result.data.start_line == 3
      assert result.data.content == "line3\nline4\nline5"
    end

    test "reads a range with both start_line and line_count", %{workspace: ws} do
      result =
        Read.run(%{"path" => "multiline.txt", "start_line" => 2, "line_count" => 2},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.content == "line2\nline3"
      assert result.data.line_count == 2
    end
  end

  describe "run/2 — error cases" do
    test "rejects workspace escape paths", %{workspace: ws} do
      result = Read.run(%{"path" => "../etc/passwd"}, workspace_root: ws)

      assert result.ok == false
      assert result.data == nil
      assert result.error.code == "workspace_escape"
      # BD-0020 envelope keys
      assert result.correlation == nil
      assert result.redactions == []
      assert result.truncated == false
    end

    test "rejects absolute paths" do
      result = Read.run(%{"path" => "/etc/passwd"}, workspace_root: "/tmp")

      assert result.ok == false
      assert result.error.code == "workspace_escape"
    end

    test "rejects non-existent file", %{workspace: ws} do
      result = Read.run(%{"path" => "nope.txt"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "not_found"
    end

    test "rejects directory path", %{workspace: ws} do
      result = Read.run(%{"path" => "."}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "not_file"
    end

    test "rejects invalid start_line", %{workspace: ws} do
      result = Read.run(%{"path" => "hello.txt", "start_line" => 0}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects excessive line_count", %{workspace: ws} do
      result =
        Read.run(%{"path" => "hello.txt", "line_count" => 10_000}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end

  describe "run/2 — truncation and limits" do
    test "truncates long output at byte limit", %{workspace: ws} do
      # Use a tiny max_bytes
      result =
        Read.run(%{"path" => "long.txt"}, workspace_root: ws, max_bytes: 50)

      assert result.ok == true
      assert byte_size(result.data.content) <= 50
    end

    test "returns start_line beyond total_lines as empty", %{workspace: ws} do
      result = Read.run(%{"path" => "hello.txt", "start_line" => 100}, workspace_root: ws)

      assert result.ok == true
      assert result.data.content == ""
      assert result.data.line_count == 0
    end
  end

  describe "run/2 — binary detection" do
    test "detects binary files", %{workspace: ws} do
      result = Read.run(%{"path" => "binary.bin"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.binary == true
    end
  end

  describe "run/2 — path with null bytes" do
    test "rejects null bytes in path", %{workspace: ws} do
      result = Read.run(%{"path" => "hello.txt\0evil"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end

  describe "run/2 — arg validation" do
    test "rejects non-string path", %{workspace: ws} do
      result = Read.run(%{"path" => 42}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects invalid start_line", %{workspace: ws} do
      result = Read.run(%{"path" => "hello.txt", "start_line" => "one"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects invalid line_count", %{workspace: ws} do
      result = Read.run(%{"path" => "hello.txt", "line_count" => -1}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end

  describe "run/2 — bounded I/O" do
    test "reads only up to max_bytes from large file", %{workspace: ws} do
      big_content = String.duplicate("x", 10_000)
      File.write!(Path.join(@workspace, "big.txt"), big_content)

      result =
        Read.run(%{"path" => "big.txt"}, workspace_root: ws, max_bytes: 1_000)

      assert result.ok == true
      assert byte_size(result.data.content) <= 1_000
    end

    test "handles file larger than max_bytes with line range", %{workspace: ws} do
      lines = Enum.map(1..500, &"line #{&1}")
      big_content = Enum.join(lines, "\n")
      File.write!(Path.join(@workspace, "biglines.txt"), big_content)

      result =
        Read.run(%{"path" => "biglines.txt", "start_line" => 10, "line_count" => 5},
          workspace_root: ws,
          max_bytes: 10_000
        )

      assert result.ok == true
      assert result.data.line_count == 5
    end
  end

  describe "run/2 — symlink path inside workspace" do
    test "reads through symlink inside workspace", %{workspace: ws} do
      link_path = Path.join(ws, "link_to_hello")
      File.ln_s!("hello.txt", link_path)

      result = Read.run(%{"path" => "link_to_hello"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.content == "hello world"
    end
  end

  describe "run/2 — rootlink/out/secret.txt ancestor escape" do
    test "rejects rootlink/out/secret.txt via ancestor symlinks", %{workspace: ws} do
      outside = "/tmp/tet_test_read_ancestor_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "EVIL")
      on_exit(fn -> File.rm_rf!(outside) end)

      rootlink = Path.join(ws, "rootlink")
      File.ln_s!(".", rootlink)
      out_link = Path.join(ws, "out")
      File.ln_s!("../outside", out_link)

      result = Read.run(%{"path" => "rootlink/out/secret.txt"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "workspace_escape"
      assert result.data == nil
    end

    test "rejects indirect_secret symlink escape via ancestor out symlink", %{workspace: ws} do
      outside = "/tmp/tet_test_read_indirect_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "EVIL_SECRET")
      on_exit(fn -> File.rm_rf!(outside) end)

      out_link = Path.join(ws, "out")
      File.ln_s!("../outside", out_link)

      indirect_link = Path.join(ws, "indirect_secret")
      File.ln_s!("out/secret.txt", indirect_link)

      result = Read.run(%{"path" => "indirect_secret"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "workspace_escape"
      assert result.data == nil
    end
  end

  describe "run/2 — BD-0020 error schema with correlation" do
    test "workspace_escape error includes correlation key", %{workspace: ws} do
      result = Read.run(%{"path" => "../etc/passwd"}, workspace_root: ws)

      assert result.ok == false

      assert Map.has_key?(result.error, :correlation),
             "error.correlation key is missing in: #{inspect(result.error)}"

      assert result.error.correlation == nil
      assert Map.has_key?(result.error, :code)
      assert Map.has_key?(result.error, :message)
      assert Map.has_key?(result.error, :kind)
      assert Map.has_key?(result.error, :retryable)
      assert Map.has_key?(result.error, :details)
    end

    test "not_found error includes correlation key", %{workspace: ws} do
      result = Read.run(%{"path" => "nonexistent.txt"}, workspace_root: ws)

      assert result.ok == false

      assert Map.has_key?(result.error, :correlation),
             "error.correlation key is missing in: #{inspect(result.error)}"

      assert result.error.correlation == nil
    end

    test "invalid_arguments error includes correlation key", %{workspace: ws} do
      result = Read.run(%{"path" => 42}, workspace_root: ws)

      assert result.ok == false

      assert Map.has_key?(result.error, :correlation),
             "error.correlation key is missing in: #{inspect(result.error)}"

      assert result.error.correlation == nil
    end

    test "not_file error includes correlation key", %{workspace: ws} do
      result = Read.run(%{"path" => "."}, workspace_root: ws)

      assert result.ok == false

      assert Map.has_key?(result.error, :correlation),
             "error.correlation key is missing in: #{inspect(result.error)}"

      assert result.error.correlation == nil
    end
  end
end
