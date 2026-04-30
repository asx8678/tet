defmodule Tet.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "doctor renders the standalone boundary through the public facade" do
    output = capture_io(fn -> assert Tet.CLI.run(["doctor"]) == 0 end)

    assert output =~ "Tet standalone doctor: ok"
    assert output =~ "tet_core, tet_store_sqlite, tet_runtime, tet_cli"
  end

  test "ask streams mock output and persists the chat turn" do
    path = tmp_path("cli")

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

  test "ask without a prompt returns a deterministic usage error" do
    output = capture_io(:stderr, fn -> assert Tet.CLI.run(["ask"]) == 64 end)

    assert output =~ "usage: tet ask PROMPT"
  end

  test "unknown commands return a deterministic usage error" do
    output = capture_io(:stderr, fn -> assert Tet.CLI.run(["web"]) == 64 end)

    assert output =~ "unknown tet command: web"
  end

  defp tmp_path(name) do
    root = Path.join(System.tmp_dir!(), "tet-cli-test-#{System.unique_integer([:positive])}")
    Path.join(root, "#{name}.jsonl")
  end

  defp with_env(vars, fun) do
    old_values = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(old_values, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
