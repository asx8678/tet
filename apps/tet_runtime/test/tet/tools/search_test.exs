defmodule Tet.Runtime.Tools.SearchTest do
  use ExUnit.Case, async: true

  alias Tet.Runtime.Tools.Search

  @workspace "/tmp/tet_test_search_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@workspace)
    File.write!(Path.join(@workspace, "hello.txt"), "hello world\nhello there\nbye now")
    File.write!(Path.join(@workspace, "stuff.txt"), "some stuff\nmore stuff\nfinal line")
    File.write!(Path.join(@workspace, "numbers.txt"), "123\n456\n789")

    File.mkdir_p!(Path.join(@workspace, "sub"))
    File.write!(Path.join(@workspace, "sub/nested.txt"), "nested hello\ndeep world")

    on_exit(fn -> File.rm_rf!(@workspace) end)

    %{workspace: @workspace}
  end

  defp skip_without_rg() do
    unless System.find_executable("rg") do
      :skip
    end
  end

  describe "run/2 — basic search" do
    test "finds literal matches", %{workspace: ws} do
      skip_without_rg()

      result = Search.run(%{"path" => ".", "query" => "hello"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.summary.match_count >= 2
      # BD-0020 envelope
      assert result.error == nil
      assert result.correlation == nil
      assert result.redactions == []
    end

    test "finds matches in subdirectories", %{workspace: ws} do
      skip_without_rg()

      result = Search.run(%{"path" => ".", "query" => "nested"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end

    test "returns empty matches for no results", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "xyznonexistent_12345"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.matches == []
      assert result.data.summary.match_count == 0
    end
  end

  describe "run/2 — search modes" do
    test "regex search works", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "hello|world", "regex" => true},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end

    test "case-insensitive search works", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "HELLO", "case_sensitive" => false},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end

    test "case-sensitive search by default filters case", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "HELLO", "case_sensitive" => true},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count == 0
    end
  end

  describe "run/2 — error cases" do
    test "rejects empty query" do
      result = Search.run(%{"path" => ".", "query" => ""}, workspace_root: "/tmp")

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
      assert result.data == nil
    end

    test "rejects nil query" do
      result = Search.run(%{"path" => ".", "query" => nil}, workspace_root: "/tmp")

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects workspace escape in path", %{workspace: ws} do
      result = Search.run(%{"path" => "../etc", "query" => "hello"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "workspace_escape"
    end

    test "rejects null bytes in path", %{workspace: ws} do
      result =
        Search.run(%{"path" => "hello.txt\0evil", "query" => "hello"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end

  describe "run/2 — missing/nonexistent path" do
    test "returns not_found for nonexistent path", %{workspace: ws} do
      result =
        Search.run(%{"path" => "nonexistent_dir", "query" => "hello"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "not_found"
      assert result.data == nil
    end

    test "returns not_found for nonexistent nested path", %{workspace: ws} do
      result =
        Search.run(%{"path" => "sub/missing", "query" => "hello"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "not_found"
    end
  end

  describe "run/2 — invalid regex handling" do
    test "returns invalid_arguments for invalid regex", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "[invalid", "regex" => true},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "returns invalid_arguments for unbalanced parens regex", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "(hello", "regex" => true},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end

  describe "run/2 — NUL byte rejection" do
    test "rejects NUL bytes in query", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello\0world"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
      assert result.data == nil
    end

    test "rejects NUL bytes in include_globs", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello", "include_globs" => ["*.txt\0evil"]},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects NUL bytes in exclude_globs", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello", "exclude_globs" => ["*.txt\0evil"]},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end

  describe "run/2 — RIPGREP_CONFIG_PATH isolation" do
    test "outside files not seen when RIPGREP_CONFIG_PATH has --follow", %{workspace: ws} do
      skip_without_rg()

      # Create an outside dir with a file that would match if followed
      outside = "/tmp/tet_test_rg_config_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "outside_secret.txt"), "SECRET_DATA")
      on_exit(fn -> File.rm_rf!(outside) end)

      # Create a symlink from inside workspace to outside
      link_path = Path.join(ws, "evil_link")
      File.ln_s!(outside, link_path)

      # Create a ripgrep config file that has --follow
      config_dir = "/tmp/tet_test_rg_config_dir_#{System.unique_integer([:positive])}"
      File.mkdir_p!(config_dir)
      config_path = Path.join(config_dir, ".ripgreprc")
      File.write!(config_path, "--follow\n")
      on_exit(fn -> File.rm_rf!(config_dir) end)

      # Search with RIPGREP_CONFIG_PATH set — should not see outside files
      original_config = System.get_env("RIPGREP_CONFIG_PATH")
      System.put_env("RIPGREP_CONFIG_PATH", config_path)

      try do
        result =
          Search.run(%{"path" => ".", "query" => "SECRET_DATA"}, workspace_root: ws)

        assert result.ok == true

        assert result.data.summary.match_count == 0,
               "RIPGREP_CONFIG_PATH with --follow should not expose outside files"
      after
        if original_config do
          System.put_env("RIPGREP_CONFIG_PATH", original_config)
        else
          System.delete_env("RIPGREP_CONFIG_PATH")
        end
      end
    end
  end

  describe "run/2 — query injection prevention" do
    test "handles queries starting with dash", %{workspace: ws} do
      skip_without_rg()

      # Query starting with '-' should be treated as literal, not flag
      result = Search.run(%{"path" => ".", "query" => "-needle"}, workspace_root: ws)

      assert result.ok == true
      assert result.data.summary.match_count == 0
    end

    test "handles -f query", %{workspace: ws} do
      skip_without_rg()

      result = Search.run(%{"path" => ".", "query" => "-f"}, workspace_root: ws)

      assert result.ok == true
    end

    test "handles --files query", %{workspace: ws} do
      skip_without_rg()

      result = Search.run(%{"path" => ".", "query" => "--files"}, workspace_root: ws)

      assert result.ok == true
    end
  end

  describe "run/2 — include/exclude globs" do
    test "include_globs filters matches to matching files", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "stuff", "include_globs" => ["*.txt"]},
          workspace_root: ws
        )

      assert result.ok == true
      assert result.data.summary.match_count >= 1
    end
  end

  describe "run/2 — arg validation" do
    test "rejects non-string path" do
      result = Search.run(%{"path" => 42, "query" => "hello"}, workspace_root: "/tmp")

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects non-boolean regex", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello", "regex" => "yes"},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects non-boolean case_sensitive", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello", "case_sensitive" => "maybe"},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects non-list include_globs", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello", "include_globs" => "*.txt"},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end

    test "rejects non-list exclude_globs", %{workspace: ws} do
      result =
        Search.run(%{"path" => ".", "query" => "hello", "exclude_globs" => 42},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end

  describe "run/2 — BD-0020 error schema with correlation" do
    test "workspace_escape error includes correlation key" do
      result = Search.run(%{"path" => "../etc", "query" => "hello"}, workspace_root: "/tmp")

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

    test "invalid_arguments error includes correlation key" do
      result = Search.run(%{"path" => ".", "query" => nil}, workspace_root: "/tmp")

      assert result.ok == false

      assert Map.has_key?(result.error, :correlation),
             "error.correlation key is missing in: #{inspect(result.error)}"

      assert result.error.correlation == nil
    end

    test "not_found error includes correlation key" do
      result =
        Search.run(%{"path" => "nonexistent_path", "query" => "hello"},
          workspace_root: "/tmp"
        )

      assert result.ok == false

      assert Map.has_key?(result.error, :correlation),
             "error.correlation key is missing in: #{inspect(result.error)}"

      assert result.error.correlation == nil
    end
  end

  describe "run/2 — envelope schema (BD-0020)" do
    test "success response has correct envelope keys", %{workspace: ws} do
      skip_without_rg()

      result = Search.run(%{"path" => ".", "query" => "hello"}, workspace_root: ws)

      assert Map.has_key?(result, :ok)
      assert Map.has_key?(result, :correlation)
      assert Map.has_key?(result, :data)
      assert Map.has_key?(result, :error)
      assert Map.has_key?(result, :redactions)
      assert Map.has_key?(result, :truncated)
      assert Map.has_key?(result, :limit_usage)
      assert result.error == nil
      assert result.redactions == []
    end

    test "error response has correct envelope keys" do
      result = Search.run(%{"path" => "../etc", "query" => "hello"}, workspace_root: "/tmp")

      assert Map.has_key?(result, :ok)
      assert Map.has_key?(result, :correlation)
      assert Map.has_key?(result, :data)
      assert Map.has_key?(result, :error)
      assert Map.has_key?(result, :redactions)
      assert Map.has_key?(result, :truncated)
      assert Map.has_key?(result, :limit_usage)
      assert result.data == nil
      assert result.redactions == []
    end
  end

  describe "run/2 — rootlink/out/secret.txt ancestor escape" do
    test "rejects rootlink/out/secret.txt via ancestor symlinks", %{workspace: ws} do
      skip_without_rg()

      outside = "/tmp/tet_test_search_ancestor_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "EVIL_SEARCH_DATA")
      on_exit(fn -> File.rm_rf!(outside) end)

      rootlink = Path.join(ws, "rootlink")
      File.ln_s!(".", rootlink)
      out_link = Path.join(ws, "out")
      File.ln_s!("../outside", out_link)

      result =
        Search.run(%{"path" => "rootlink/out", "query" => "EVIL_SEARCH_DATA"}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "workspace_escape"
      assert result.data == nil
    end

    test "rejects indirect_dir search via ancestor out symlink escape", %{workspace: ws} do
      skip_without_rg()

      outside = "/tmp/tet_test_search_indirect_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.mkdir_p!(Path.join(outside, "subdir"))
      File.write!(Path.join(outside, "subdir/secret.txt"), "SECRET_DIR_DATA")
      on_exit(fn -> File.rm_rf!(outside) end)

      out_link = Path.join(ws, "out")
      File.ln_s!("../outside", out_link)

      indirect_dir = Path.join(ws, "indirect_dir")
      File.ln_s!("out/subdir", indirect_dir)

      result =
        Search.run(%{"path" => "indirect_dir", "query" => "SECRET_DIR_DATA"},
          workspace_root: ws
        )

      assert result.ok == false
      assert result.error.code == "workspace_escape"
      assert result.data == nil
    end
  end

  describe "run/2 — workspace_root as symlink (Issue 2: absolute path leak)" do
    test "match paths are workspace-relative, not absolute, when workspace_root is a symlink",
         %{workspace: ws} do
      skip_without_rg()

      # Create a symlink that points to the real workspace
      symlink_root =
        "/tmp/tet_test_search_symlink_root_#{System.unique_integer([:positive])}"

      File.ln_s!(ws, symlink_root)
      on_exit(fn -> File.rm(symlink_root) end)

      result =
        Search.run(%{"path" => ".", "query" => "hello"}, workspace_root: symlink_root)

      assert result.ok == true
      assert result.data.summary.match_count >= 1

      for match <- result.data.matches do
        refute String.starts_with?(match.path, "/"),
               "Match path should NOT be absolute: #{inspect(match.path)}"

        refute String.contains?(match.path, ".."),
               "Match path should not contain traversal: #{inspect(match.path)}"
      end

      first_path = List.first(result.data.matches).path

      assert first_path == "hello.txt" or String.starts_with?(first_path, "sub/"),
             "Expected workspace-relative path like 'hello.txt', got: #{first_path}"
    end
  end

  describe "run/2 — RIPGREP_CONFIG_PATH adversarial with symlink" do
    test "outside symlink content not found even with evil RIPGREP_CONFIG_PATH", %{workspace: ws} do
      skip_without_rg()

      outside = "/tmp/tet_test_rg_evil_#{System.unique_integer([:positive])}"
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "evil_secret.txt"), "EVIL_CONFIG_DATA")
      on_exit(fn -> File.rm_rf!(outside) end)

      symlink = Path.join(ws, "evil_symlink")
      File.ln_s!(outside, symlink)

      # Create a ripgreprc that enables --follow
      config_dir = "/tmp/tet_test_rg_evil_conf_#{System.unique_integer([:positive])}"
      File.mkdir_p!(config_dir)
      config_path = Path.join(config_dir, ".ripgreprc")
      File.write!(config_path, "--follow\n")
      on_exit(fn -> File.rm_rf!(config_dir) end)

      original_config = System.get_env("RIPGREP_CONFIG_PATH")
      System.put_env("RIPGREP_CONFIG_PATH", config_path)

      try do
        result = Search.run(%{"path" => ".", "query" => "EVIL_CONFIG_DATA"}, workspace_root: ws)

        assert result.ok == true,
               "RIPGREP_CONFIG_PATH with --follow should not expose outside files"

        assert result.data.summary.match_count == 0
      after
        if original_config,
          do: System.put_env("RIPGREP_CONFIG_PATH", original_config),
          else: System.delete_env("RIPGREP_CONFIG_PATH")
      end
    end
  end

  describe "run/2 — malformed search inputs" do
    test "missing search path returns not_found before invoking rg" do
      result =
        Search.run(%{"path" => "nonexistent_path_xyzzy", "query" => "hello"},
          workspace_root: "/tmp"
        )

      assert result.ok == false
      assert result.error.code == "not_found"
    end

    test "invalid regex returns invalid_arguments", %{workspace: ws} do
      skip_without_rg()

      result =
        Search.run(%{"path" => ".", "query" => "(unclosed", "regex" => true}, workspace_root: ws)

      assert result.ok == false
      assert result.error.code == "invalid_arguments"
    end
  end

  describe "run/2 — truncation and resource bounds" do
    test "truncated flagged when max matches exceeded", %{workspace: ws} do
      skip_without_rg()

      # Create a file with more than 200 matches
      lines = Enum.map(1..300, &"match_line_#{&1}")
      content = Enum.join(lines, "\n")
      File.write!(Path.join(ws, "many_matches.txt"), content)

      result = Search.run(%{"path" => ".", "query" => "match_line"}, workspace_root: ws)

      assert result.ok == true
      assert result.truncated == true
      assert length(result.data.matches) <= 200
    end

    test "truncated flagged when max paths exceeded", %{workspace: ws} do
      skip_without_rg()

      # Create >100 files each with a match
      for i <- 1..105 do
        File.write!(Path.join(ws, "file_#{i}.txt"), "unique_match_line_#{i}")
      end

      result = Search.run(%{"path" => ".", "query" => "unique_match_line"}, workspace_root: ws)

      assert result.ok == true
      assert result.truncated == true
    end
  end
end
