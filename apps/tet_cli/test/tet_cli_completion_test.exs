defmodule Tet.CLI.CompletionTest do
  use ExUnit.Case, async: true

  alias Tet.CLI.Completion

  describe "commands/0" do
    test "returns a non-empty map of commands" do
      cmds = Completion.commands()
      assert is_map(cmds)
      assert map_size(cmds) > 0
    end

    test "includes core commands" do
      names = Completion.command_names()
      assert "ask" in names
      assert "doctor" in names
      assert "profiles" in names
      assert "sessions" in names
      assert "help" in names
    end

    test "includes new UX commands" do
      names = Completion.command_names()
      assert "completion" in names
      assert "history" in names
    end
  end

  describe "command_names/0" do
    test "returns sorted command names" do
      names = Completion.command_names()
      assert names == Enum.sort(names)
    end
  end

  describe "generate/1" do
    test "generates bash completion script" do
      assert {:ok, script} = Completion.generate("bash")
      assert is_binary(script)
      assert script =~ "_tet_completions"
      assert script =~ "complete -F _tet_completions tet"
    end

    test "generates zsh completion script" do
      assert {:ok, script} = Completion.generate("zsh")
      assert is_binary(script)
      assert script =~ "#compdef tet"
      assert script =~ "_tet()"
    end

    test "generates fish completion script" do
      assert {:ok, script} = Completion.generate("fish")
      assert is_binary(script)
      assert script =~ "complete -c tet"
    end

    test "rejects unsupported shells" do
      assert {:error, {:unsupported_shell, "powershell"}} = Completion.generate("powershell")
    end

    test "rejects invalid input" do
      assert {:error, {:unsupported_shell, "unknown"}} = Completion.generate("unknown")
    end
  end

  describe "generate_bash/0" do
    test "includes all command names in completions" do
      script = Completion.generate_bash()
      names = Completion.command_names()

      for name <- names do
        assert script =~ name, "bash script missing command: #{name}"
      end
    end

    test "includes profile subcommands" do
      script = Completion.generate_bash()
      assert script =~ "show"
    end

    test "includes --fuzzy option for history" do
      script = Completion.generate_bash()
      assert script =~ "--fuzzy"
    end

    test "does not alter runtime policy (UX only)" do
      script = Completion.generate_bash()
      assert script =~ "UX only"
    end
  end

  describe "generate_zsh/0" do
    test "includes command descriptions" do
      script = Completion.generate_zsh()
      assert script =~ "Stream a reply"
      assert script =~ "Check config"
    end

    test "includes subcommand options" do
      script = Completion.generate_zsh()
      assert script =~ "--session"
      assert script =~ "--fuzzy"
      assert script =~ "--limit"
    end

    test "uses $words[2] for subcommand dispatch" do
      script = Completion.generate_zsh()
      assert script =~ "$words[2]"
      refute script =~ "$words[1]"
    end
  end

  describe "generate_fish/0" do
    test "includes command completions with descriptions" do
      script = Completion.generate_fish()
      assert script =~ "complete -c tet"
      assert script =~ "-a 'ask'"
      assert script =~ "-d '"
    end

    test "includes option completions for commands with options" do
      script = Completion.generate_fish()
      # ask has --session
      assert script =~ "--session" || script =~ "session"
    end
  end
end
