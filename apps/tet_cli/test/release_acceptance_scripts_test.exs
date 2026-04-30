defmodule TetCLI.ReleaseAcceptanceScriptsTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @scripts [
    "tools/check_release_acceptance.sh",
    "tools/smoke_first_mile.sh"
  ]

  test "release acceptance scripts are executable and syntax-checkable" do
    bash = System.find_executable("bash") || flunk("bash is required for release scripts")

    for script <- @scripts do
      path = Path.join(@root, script)

      assert File.exists?(path), "missing #{script}"
      assert executable?(path), "#{script} must be executable"
      assert {"", 0} = System.cmd(bash, ["-n", script], cd: @root, stderr_to_stdout: true)
    end
  end

  test "release acceptance help documents the final gates" do
    {output, 0} =
      System.cmd(Path.join(@root, "tools/check_release_acceptance.sh"), ["--help"],
        cd: @root,
        stderr_to_stdout: true
      )

    assert output =~ "BD-0074"
    assert output =~ "mix format --check-formatted"
    assert output =~ "full ExUnit suite"
    assert output =~ "offline first-mile release smoke"
    assert output =~ "web removability sandbox gate"
  end

  test "first-mile smoke help promises offline mock-provider execution" do
    {output, 0} =
      System.cmd(Path.join(@root, "tools/smoke_first_mile.sh"), ["--help"],
        cd: @root,
        stderr_to_stdout: true
      )

    assert output =~ "offline first-mile smoke"
    assert output =~ "sanitized env"
    assert output =~ "caller TET_* config"
    assert output =~ "TET_PROVIDER=mock"
    assert output =~ "network, secrets, and SSH cannot affect the smoke"
  end

  test "first-mile smoke sanitizes caller Tet registry environment" do
    script = File.read!(Path.join(@root, "tools/smoke_first_mile.sh"))

    assert script =~ "env -i"
    assert script =~ "TET_MODEL_REGISTRY_PATH="
    assert script =~ "TET_PROFILE_REGISTRY_PATH="
    assert script =~ "TET_PROFILE="
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      {:error, _reason} -> false
    end
  end
end
