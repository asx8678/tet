defmodule Tet.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "doctor renders the standalone boundary through the public facade" do
    output = capture_io(fn -> assert Tet.CLI.run(["doctor"]) == 0 end)

    assert output =~ "Tet standalone doctor: ok"
    assert output =~ "tet_core, tet_store_sqlite, tet_runtime, tet_cli"
  end

  test "unknown commands return a deterministic usage error" do
    output = capture_io(:stderr, fn -> assert Tet.CLI.run(["web"]) == 64 end)

    assert output =~ "unknown tet command: web"
  end
end
