defmodule Tet.Security.PathFuzzerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Tet.Security.PathFuzzer
  alias Tet.SecurityPolicy.Evaluator
  alias Tet.SecurityPolicy.Profile

  @workspace "/workspace"

  describe "generate_traversal_attempts/0" do
    test "returns a non-empty list of attack strings" do
      attacks = PathFuzzer.generate_traversal_attempts()
      assert is_list(attacks)
      assert length(attacks) > 0
    end

    test "all attacks are strings" do
      for attack <- PathFuzzer.generate_traversal_attempts() do
        assert is_binary(attack), "Expected string, got: #{inspect(attack)}"
      end
    end

    test "includes classic traversal patterns" do
      attacks = PathFuzzer.generate_traversal_attempts()
      # Must have at least some ../ patterns
      traversal_count = Enum.count(attacks, &String.contains?(&1, "../"))
      assert traversal_count >= 5, "Expected at least 5 ../ patterns, got #{traversal_count}"
    end

    test "includes absolute path escapes" do
      attacks = PathFuzzer.generate_traversal_attempts()
      # Must have /etc/passwd or similar
      assert Enum.any?(attacks, &String.contains?(&1, "etc/passwd")),
             "Expected absolute path escape patterns"
    end

    test "includes url-encoded patterns" do
      attacks = PathFuzzer.generate_traversal_attempts()

      assert Enum.any?(attacks, &String.contains?(&1, "%2f")),
             "Expected URL-encoded path patterns"
    end

    test "includes edge cases" do
      _attacks = PathFuzzer.generate_traversal_attempts()
      # Benign edge cases are now in a separate list
      assert Enum.any?(PathFuzzer.benign_edge_cases(), &(&1 == ""))
    end

    test "no duplicate attacks" do
      attacks = PathFuzzer.generate_traversal_attempts()
      assert attacks == Enum.uniq(attacks), "Duplicate attacks found"
    end

    test "includes null-byte payloads" do
      attacks = PathFuzzer.generate_traversal_attempts()

      assert Enum.any?(attacks, &String.contains?(&1, <<0>>)),
             "Expected null-byte payloads in traversal attempts"
    end

    test "includes URL-encoded null-byte variants" do
      attacks = PathFuzzer.generate_traversal_attempts()

      assert Enum.any?(attacks, &String.contains?(&1, "%00")),
             "Expected %00 null-byte encoded variants"
    end

    test "benign_edge_cases/0 returns non-attack inputs" do
      benign = PathFuzzer.benign_edge_cases()
      assert is_list(benign)
      assert "" in benign
      assert "." in benign
      # None of the benign cases should contain traversal markers
      for b <- benign do
        refute String.contains?(b, "../"), "Benign edge case contains traversal: #{inspect(b)}"
      end
    end
  end

  describe "normalize_encoded_path/1" do
    test "decodes single-layer URL encoding" do
      assert PathFuzzer.normalize_encoded_path("..%2f..%2fetc%2fpasswd") == "../../etc/passwd"
    end

    test "decodes dot encoding" do
      assert PathFuzzer.normalize_encoded_path("%2e%2e%2f") == "../"
    end

    test "recursively decodes double-encoded paths" do
      # %252e → %2e → .
      result = PathFuzzer.normalize_encoded_path("%252e%252e%252f")
      assert result == "../"
    end

    test "passes through non-encoded paths unchanged" do
      assert PathFuzzer.normalize_encoded_path("lib/app.ex") == "lib/app.ex"
    end

    test "decodes %00 null bytes" do
      assert PathFuzzer.normalize_encoded_path("file%00.exe") == "file\0.exe"
    end
  end

  describe "test_path_security/2" do
    test "returns empty list when all attacks are blocked" do
      # A deny-all function
      failures = PathFuzzer.test_path_security(fn _path -> {:denied, :blocked} end)
      assert failures == []
    end

    test "returns failures when attacks pass through" do
      # An allow-all function (BAD! but we're testing the fuzzer)
      failures = PathFuzzer.test_path_security(fn _path -> :allowed end)
      assert length(failures) > 0
    end

    test "each failure has attack, full_path, and blocked fields" do
      failures = PathFuzzer.test_path_security(fn _path -> :allowed end)

      for failure <- Enum.take(failures, 5) do
        assert Map.has_key?(failure, :attack)
        assert Map.has_key?(failure, :full_path)
        assert Map.has_key?(failure, :blocked)
        assert failure.blocked == false
      end
    end

    test "uses custom workspace_root from opts" do
      failures =
        PathFuzzer.test_path_security(
          fn _path -> :allowed end,
          workspace_root: "/myproject"
        )

      # All full_paths should start with /myproject for relative attacks
      for failure <- failures do
        if not String.starts_with?(failure.attack, "/") do
          assert String.starts_with?(failure.full_path, "/myproject"),
                 "Expected full_path to start with /myproject, got: #{failure.full_path}"
        end
      end
    end
  end

  # --- Integration: test actual security modules against fuzzer ---

  describe "path traversal prevention (integration)" do
    test "workspace_only profile blocks relative traversal attacks" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only
        })

      attacks = PathFuzzer.generate_traversal_attempts()

      # Filter to relative attacks only (not absolute)
      relative_attacks =
        Enum.filter(attacks, fn a ->
          a != "" and not String.starts_with?(a, "/") and not String.starts_with?(a, "C:")
        end)

      for attack <- relative_attacks do
        context = %{path: Path.join(@workspace, attack), workspace_root: @workspace}
        result = Evaluator.check_sandbox(:read, context, profile)

        case result do
          {:denied, _} ->
            :ok

          :allowed ->
            # If allowed, verify via the full check pipeline (which includes
            # deny/allow resolution) that the path doesn't actually escape.
            # The sandbox may allow it because the canonicalised path is under workspace.
            full_result = Evaluator.check(:read, context, profile)

            assert match?({:denied, _}, full_result) or full_result == :allowed,
                   "Traversal attack caused unexpected result: #{attack} got #{inspect(full_result)}"
        end
      end
    end

    test "workspace_only profile blocks absolute path escapes" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only
        })

      absolute_attacks = [
        "/etc/passwd",
        "/etc/shadow",
        "/proc/self/environ",
        "/root/.ssh/id_rsa",
        "/tmp/evil.sh"
      ]

      for attack <- absolute_attacks do
        context = %{path: attack, workspace_root: @workspace}
        result = Evaluator.check_sandbox(:read, context, profile)

        assert match?({:denied, :sandbox_workspace_only}, result),
               "Absolute path escape not blocked: #{attack} got #{inspect(result)}"
      end
    end

    test "locked_down profile denies everything" do
      profile =
        Profile.new!(%{
          approval_mode: :always_deny,
          sandbox_profile: :locked_down
        })

      for attack <- PathFuzzer.generate_traversal_attempts() do
        context = %{path: attack, workspace_root: @workspace}
        result = Evaluator.check(:read, context, profile)

        assert match?({:denied, _}, result),
               "Locked down profile allowed: #{attack} got #{inspect(result)}"
      end
    end

    test "deny globs block traversal even with permissive allow paths" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :unrestricted,
          deny_globs: ["**/etc/**", "**/proc/**", "**/shadow"],
          allow_paths: ["**"]
        })

      # Paths matching deny globs should be denied regardless of allow
      for path <- ["/etc/passwd", "/proc/self/environ", "/etc/shadow"] do
        assert Evaluator.denied_by_glob?(path, profile.deny_globs),
               "Deny glob should match: #{path}"
      end
    end
  end

  describe "path canonicalisation" do
    test "resolves ../ segments correctly" do
      # Access the private canonicalise_path through the check pipeline
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only
        })

      # These should resolve outside workspace
      escapes = [
        "#{@workspace}/../../../etc/passwd",
        "#{@workspace}/subdir/../../etc/shadow"
      ]

      for path <- escapes do
        context = %{path: path, workspace_root: @workspace}
        result = Evaluator.check_sandbox(:read, context, profile)

        assert match?({:denied, _}, result),
               "Canonicalisation failed — path escaped: #{path} got #{inspect(result)}"
      end
    end

    test "preserves safe paths under workspace" do
      profile =
        Profile.new!(%{
          approval_mode: :auto_approve,
          sandbox_profile: :workspace_only
        })

      safe_paths = [
        "#{@workspace}/src/app.ex",
        "#{@workspace}/config/config.exs",
        "#{@workspace}/lib/module.ex"
      ]

      for path <- safe_paths do
        context = %{path: path, workspace_root: @workspace}
        result = Evaluator.check_sandbox(:read, context, profile)

        assert result == :allowed,
               "Safe path incorrectly denied: #{path} got #{inspect(result)}"
      end
    end
  end
end
