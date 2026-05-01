defmodule Tet.Runtime.Tools.EventCaptureTest do
  use ExUnit.Case, async: false

  alias Tet.Runtime.Tools.EventCapture
  alias Tet.Event

  @workspace "/tmp/tet_test_event_capture_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@workspace)

    # Write a small file
    File.write!(Path.join(@workspace, "hello.txt"), "hello world\nline two\nline three\n")

    # Write a binary file
    File.write!(Path.join(@workspace, "binary.bin"), <<0, 1, 2, 3, 4, 5>>)

    # Write a large-ish file
    large_content = String.duplicate("line of text\n", 1_000)
    File.write!(Path.join(@workspace, "large.txt"), large_content)

    on_exit(fn -> File.rm_rf!(@workspace) end)
    %{workspace: @workspace}
  end

  describe "run/3 with read tool" do
    test "emits started and completed events on success", %{workspace: ws} do
      {:ok, result, [started, completed]} =
        EventCapture.run("read", %{"path" => "hello.txt"}, workspace_root: ws,
          session_id: "ses_test_read")

      assert result.ok == true

      # Started event
      assert started.type == :"read_tool.started"
      assert started.session_id == "ses_test_read"
      assert started.payload.tool_name == "read"
      assert started.payload.redaction_class == :workspace_content
      assert is_map(started.payload.args)

      # Completed event
      assert completed.type == :"read_tool.completed"
      assert completed.session_id == "ses_test_read"
      assert completed.payload.ok == true
      assert completed.payload.tool_name == "read"
      assert completed.payload.result_summary.bytes_read > 0
      assert completed.payload.result_summary.line_count > 0
    end

    test "emits error event when tool fails", %{workspace: ws} do
      {:error, result, [_started, completed]} =
        EventCapture.run("read", %{"path" => "nonexistent.txt"}, workspace_root: ws,
          session_id: "ses_test_err")

      assert result.ok == false

      assert completed.payload.ok == false
      assert completed.payload.result_summary.error_code == "not_found"
      assert completed.payload.result_summary.error_message != ""
    end

    test "includes correlation metadata", %{workspace: ws} do
      {:ok, _result, [started, completed]} =
        EventCapture.run("read", %{"path" => "hello.txt"}, workspace_root: ws,
          session_id: "ses_corr",
          task_id: "task_1",
          tool_call_id: "call_1")

      assert started.metadata.correlation.session_id == "ses_corr"
      assert started.metadata.correlation.task_id == "task_1"
      assert started.metadata.correlation.tool_call_id == "call_1"

      assert completed.metadata.correlation.session_id == "ses_corr"
      assert completed.metadata.correlation.task_id == "task_1"
      assert completed.metadata.correlation.tool_call_id == "call_1"
    end

    test "includes optional redaction class", %{workspace: ws} do
      {:ok, _result, [_started, completed]} =
        EventCapture.run("list", %{"path" => "."}, workspace_root: ws,
          session_id: "ses_redact",
          redaction_class: :workspace_metadata)

      assert completed.payload.redaction_class == :workspace_metadata
    end
  end

  describe "run/3 with list tool" do
    test "emits events with entry summary", %{workspace: ws} do
      {:ok, result, [_started, completed]} =
        EventCapture.run("list", %{"path" => "."}, workspace_root: ws,
          session_id: "ses_list")

      assert result.ok == true

      assert completed.type == :"read_tool.completed"
      assert completed.payload.tool_name == "list"
      assert completed.payload.result_summary.entry_count >= 3
      assert completed.payload.result_summary.file_count >= 2
      assert completed.payload.ok == true
    end
  end

  describe "run/3 with search tool" do
    test "emits events with match summary", %{workspace: ws} do
      {:ok, result, [_started, completed]} =
        EventCapture.run("search", %{"path" => ".", "query" => "hello"}, workspace_root: ws,
          session_id: "ses_search")

      assert result.ok == true

      assert completed.type == :"read_tool.completed"
      assert completed.payload.tool_name == "search"
      assert completed.payload.result_summary.match_count >= 1
      assert completed.payload.result_summary.file_count >= 1
      assert completed.payload.ok == true
    end
  end

  describe "summary_args/1" do
    test "extracts known keys" do
      result = EventCapture.summary_args(%{
        "path" => "/some/path",
        "query" => "search term",
        "start_line" => 1,
        "line_count" => 100,
        "recursive" => true,
        "some_extra" => "should be filtered"
      })

      assert result["path"] == "/some/path"
      assert result["query"] == "search term"
      assert result["start_line"] == 1
      assert result["line_count"] == 100
      assert result["recursive"] == true
      refute Map.has_key?(result, "some_extra")
    end

    test "truncates long string values" do
      long_str = String.duplicate("a", 1_000)
      result = EventCapture.summary_args(%{"path" => long_str})

      assert byte_size(result["path"]) <= 515
      assert String.ends_with?(result["path"], "...")
    end
  end

  describe "event types" do
    test "read_tool types are registered in known_types" do
      assert :"read_tool.started" in Event.known_types()
      assert :"read_tool.completed" in Event.known_types()
    end

    test "read_tool_types/0 returns the expected types" do
      assert Event.read_tool_types() == [
               :"read_tool.started",
               :"read_tool.completed"
             ]
    end
  end
end
