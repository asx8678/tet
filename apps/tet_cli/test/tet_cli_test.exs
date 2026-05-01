defmodule Tet.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tet.CLI.Render

  setup do
    tmp_root = unique_tmp_root("tet-cli-test")

    File.rm_rf!(tmp_root)
    File.mkdir_p!(tmp_root)

    old_events_path = System.get_env("TET_EVENTS_PATH")
    old_profile_registry_path = System.get_env("TET_PROFILE_REGISTRY_PATH")
    old_model_registry_path = System.get_env("TET_MODEL_REGISTRY_PATH")
    System.delete_env("TET_EVENTS_PATH")
    System.delete_env("TET_PROFILE_REGISTRY_PATH")
    System.delete_env("TET_MODEL_REGISTRY_PATH")

    on_exit(fn ->
      restore_env(%{
        "TET_EVENTS_PATH" => old_events_path,
        "TET_PROFILE_REGISTRY_PATH" => old_profile_registry_path,
        "TET_MODEL_REGISTRY_PATH" => old_model_registry_path
      })

      File.rm_rf!(tmp_root)
    end)

    {:ok, tmp_root: tmp_root}
  end

  test "doctor renders the standalone boundary through the public facade", %{tmp_root: tmp_root} do
    with_env(%{"TET_STORE_PATH" => tmp_path(tmp_root, "doctor")}, fn ->
      output = capture_io(fn -> assert Tet.CLI.run(["doctor"]) == 0 end)

      assert output =~ "Tet standalone doctor: ok"
      assert output =~ "tet_core, tet_store_sqlite, tet_runtime, tet_cli"
      assert output =~ "[ok] config"
      assert output =~ "[ok] store"
      assert output =~ "[ok] provider"
      assert output =~ "[ok] release_boundary"
    end)
  end

  test "doctor reports selected OpenAI-compatible provider missing config", %{tmp_root: tmp_root} do
    with_env(
      %{
        "TET_PROVIDER" => "openai_compatible",
        "TET_OPENAI_API_KEY" => nil,
        "TET_STORE_PATH" => tmp_path(tmp_root, "doctor-openai")
      },
      fn ->
        output = capture_io(fn -> assert Tet.CLI.run(["doctor"]) == 1 end)

        assert output =~ "Tet standalone doctor: error"
        assert output =~ "[error] provider"
        assert output =~ "TET_OPENAI_API_KEY"
      end
    )
  end

  test "profile commands list and inspect configured descriptors" do
    list_output = capture_io(fn -> assert Tet.CLI.run(["profiles"]) == 0 end)

    assert list_output =~ "Profiles:"
    assert list_output =~ "chat  model=openai/gpt-4o-mini"
    assert list_output =~ "overlays=prompt,tool,model,task,schema,cache"

    show_output = capture_io(fn -> assert Tet.CLI.run(["profile", "show", "chat"]) == 0 end)

    assert show_output =~ "Profile chat"
    assert show_output =~ "display_name: Chat"
    assert show_output =~ "model: default=openai/gpt-4o-mini fallbacks=mock/default"
    assert show_output =~ "prompt: %{"
    assert show_output =~ "tool: %{"
    assert show_output =~ "cache: %{"
  end

  test "missing profile returns not found status" do
    output =
      capture_io(:stderr, fn -> assert Tet.CLI.run(["profile", "show", "missing"]) == 66 end)

    assert output =~ "profile not found"
  end

  test "renderer formats profile and model registry validation error lists" do
    errors = [
      Tet.ProfileRegistry.error(["profiles"], :invalid_value, "profiles must declare entries"),
      Tet.ModelRegistry.error(["models"], :invalid_value, "models must declare entries")
    ]

    assert Render.error(errors) ==
             "profiles: profiles must declare entries; models: models must declare entries"
  end

  test "ask streams mock output and persists the chat turn", %{tmp_root: tmp_root} do
    path = tmp_path(tmp_root, "cli")

    with_env(%{"TET_PROVIDER" => "mock", "TET_STORE_PATH" => path}, fn ->
      output = capture_io(fn -> assert Tet.CLI.run(["ask", "hello", "cli"]) == 0 end)

      assert output == "mock: hello cli\n"

      persisted = File.read!(path)
      assert persisted =~ ~s("role":"user")
      assert persisted =~ ~s("content":"hello cli")
      assert persisted =~ ~s("role":"assistant")
      assert persisted =~ ~s("content":"mock: hello cli")
    end)
  end

  test "timeline renderer formats a deterministic core event snapshot" do
    events = [
      %Tet.Event{
        type: :message_persisted,
        session_id: "ses_demo",
        sequence: 1,
        payload: %{"message_id" => "msg_user", "role" => "user"},
        metadata: %{"timestamp" => "2025-01-01T00:00:00.000Z"}
      },
      %Tet.Event{
        type: :assistant_chunk,
        session_id: "ses_demo",
        sequence: 2,
        payload: %{"content" => "hello world", "provider" => "mock"},
        metadata: %{"timestamp" => "2025-01-01T00:00:00.001Z"}
      }
    ]

    expected =
      [
        "Events:",
        "  #1 2025-01-01T00:00:00.000Z session=ses_demo message_persisted role=user message_id=msg_user",
        "  #2 2025-01-01T00:00:00.001Z session=ses_demo assistant_chunk content=\"hello world\" provider=mock"
      ]
      |> Enum.join("\n")

    assert Render.events(events) == expected
  end

  test "events command renders persisted timeline with CLI parity snapshot", %{tmp_root: tmp_root} do
    path = tmp_path(tmp_root, "events")
    session_id = "cli-events-session"

    with_env(%{"TET_PROVIDER" => "mock", "TET_STORE_PATH" => path}, fn ->
      output =
        capture_io(fn ->
          assert Tet.CLI.run(["ask", "--session", session_id, "timeline", "cli"]) == 0
        end)

      assert output == "mock: timeline cli\n"

      assert {:ok, events} = Tet.list_events(session_id, store_path: path)
      expected = Render.events(events) <> "\n"

      event_output =
        capture_io(fn -> assert Tet.CLI.run(["events", "--session", session_id]) == 0 end)

      alias_output =
        capture_io(fn -> assert Tet.CLI.run(["timeline", "--session=#{session_id}"]) == 0 end)

      assert event_output == expected
      assert alias_output == expected
      assert event_output =~ "message_persisted role=user"
      assert event_output =~ "assistant_chunk content=\"mock\" provider=mock"
    end)
  end

  test "session commands list and show resumed messages", %{tmp_root: tmp_root} do
    path = tmp_path(tmp_root, "sessions")
    session_id = "cli-resume-session"

    with_env(%{"TET_PROVIDER" => "mock", "TET_STORE_PATH" => path}, fn ->
      first =
        capture_io(fn -> assert Tet.CLI.run(["ask", "--session", session_id, "first"]) == 0 end)

      second =
        capture_io(fn ->
          assert Tet.CLI.run(["ask", "--session=#{session_id}", "second"]) == 0
        end)

      assert first == "mock: first\n"
      assert second == "mock: second\n"

      sessions = capture_io(fn -> assert Tet.CLI.run(["sessions"]) == 0 end)
      assert sessions =~ "Sessions:"
      assert sessions =~ session_id
      assert sessions =~ "messages=4"

      shown = capture_io(fn -> assert Tet.CLI.run(["session", "show", session_id]) == 0 end)
      assert shown =~ "Session #{session_id}"
      assert shown =~ "messages: 4"
      assert shown =~ "[user] first"
      assert shown =~ "[assistant] mock: first"
      assert shown =~ "[user] second"
      assert shown =~ "[assistant] mock: second"
    end)
  end

  test "ask without a prompt returns a deterministic usage error" do
    output = capture_io(:stderr, fn -> assert Tet.CLI.run(["ask"]) == 64 end)

    assert output =~ "usage: tet ask [--session SESSION_ID] PROMPT"
  end

  test "unknown commands return a deterministic usage error" do
    output = capture_io(:stderr, fn -> assert Tet.CLI.run(["web"]) == 64 end)

    assert output =~ "unknown tet command: web"
  end

  test "completion command generates bash script" do
    output = capture_io(fn -> assert Tet.CLI.run(["completion", "bash"]) == 0 end)

    assert output =~ "_tet_completions"
    assert output =~ "complete -F _tet_completions tet"
  end

  test "completion command generates zsh script" do
    output = capture_io(fn -> assert Tet.CLI.run(["completion", "zsh"]) == 0 end)

    assert output =~ "#compdef tet"
  end

  test "completion command generates fish script" do
    output = capture_io(fn -> assert Tet.CLI.run(["completion", "fish"]) == 0 end)

    assert output =~ "complete -c tet"
  end

  test "completion command rejects unsupported shell" do
    output = capture_io(:stderr, fn -> assert Tet.CLI.run(["completion", "powershell"]) == 1 end)

    assert output =~ "tet completion failed"
  end

  test "completion command without args returns usage error" do
    output = capture_io(:stderr, fn -> assert Tet.CLI.run(["completion"]) == 64 end)

    assert output =~ "usage: tet completion <bash|zsh|fish>"
  end

  test "history command without subcommand returns usage error" do
    output = capture_io(:stderr, fn -> assert Tet.CLI.run(["history"]) == 64 end)

    assert output =~ "usage: tet history search"
  end

  test "history search without query returns usage error" do
    output = capture_io(:stderr, fn -> assert Tet.CLI.run(["history", "search"]) == 64 end)

    assert output =~ "usage: tet history search"
  end

  test "history search --fuzzy flag enables fuzzy mode" do
    output =
      capture_io(fn ->
        assert Tet.CLI.run(["history", "search", "--fuzzy", "test"]) == 0
      end)

    # The command should succeed (even with no entries)
    assert output =~ "History entries" or output =~ "No matching history entries"
  end

  test "history search invalid --limit returns error with exit 64" do
    output =
      capture_io(:stderr, fn ->
        assert Tet.CLI.run(["history", "search", "--limit", "abc", "test"]) == 64
      end)

    assert output =~ "invalid --limit value"
  end

  test "history search --limit without value returns error with exit 64" do
    output =
      capture_io(:stderr, fn ->
        assert Tet.CLI.run(["history", "search", "--limit"]) == 64
      end)

    assert output =~ "--limit requires"
  end

  defp tmp_path(tmp_root, name), do: Path.join(tmp_root, "#{name}.jsonl")

  defp unique_tmp_root(prefix) do
    suffix = "#{System.pid()}-#{System.system_time(:nanosecond)}-#{unique_integer()}"
    Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
  end

  defp unique_integer do
    System.unique_integer([:positive, :monotonic])
  end

  defp with_env(vars, fun) do
    old_values = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    try do
      fun.()
    after
      restore_env(old_values)
    end
  end

  defp restore_env(vars) do
    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
