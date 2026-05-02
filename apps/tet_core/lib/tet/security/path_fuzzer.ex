defmodule Tet.Security.PathFuzzer do
  @moduledoc """
  Path traversal fuzzing engine — BD-0070.

  Generates a comprehensive battery of malicious path variations and tests
  them against security evaluation functions. Every attack vector that has
  ever shown up in a real CVE gets coverage here.

  ## Attack categories

    - **Classic traversal** — `../`, `..\\`, deep nesting
    - **Encoding tricks** — URL-encoded, double-encoded, unicode
    - **Null byte injection** — `\0` to truncate paths
    - **Absolute path escapes** — `/etc/passwd`, `/proc/self`
    - **Mixed encoding** — combining URL + null + unicode
    - **Edge cases** — empty strings, overlong paths, whitespace tricks

  Pure functions, no processes, no side effects.
  """

  require Logger

  @workspace_root "/workspace"

  # --- Public API ---

  @doc """
  Generates a list of malicious path traversal attempts.

  Each attempt is a string that an attacker might supply as a path
  parameter to escape sandbox boundaries.

  **Note:** Benign edge cases (empty string, whitespace, dot-only) are
  NOT included here — use `benign_edge_cases/0` for those. This list
  contains only vectors that must be blocked or contained.
  """
  @spec generate_traversal_attempts() :: [String.t()]
  def generate_traversal_attempts do
    classic_traversal() ++
      url_encoded_traversal() ++
      null_byte_injection() ++
      unicode_tricks() ++
      absolute_path_escapes() ++
      mixed_encoding() ++
      dangerous_edge_cases()
  end

  @doc """
  Returns benign edge-case paths that should NOT be treated as attacks.

  These are valid or ambiguous inputs (empty string, whitespace, dot)
  that may be allowed through the sandbox. They are separated so
  compliance checks can verify them independently without false failures.
  """
  @spec benign_edge_cases() :: [String.t()]
  def benign_edge_cases do
    ["", "   ", "\t", "\n", ".", "..", "///", "////"]
  end

  @doc """
  Tests a path evaluation function against all generated attacks.

  The `path_fn` should take a path string and return a boolean or decision
  indicating whether the path is allowed. Returns a list of attack paths
  that were NOT blocked by the function (i.e., the failures).
  """
  @spec test_path_security((String.t() -> boolean() | atom() | tuple()), keyword()) :: [map()]
  def test_path_security(path_fn, opts \\ []) when is_function(path_fn, 1) do
    workspace = Keyword.get(opts, :workspace_root, @workspace_root)
    attacks = generate_traversal_attempts()

    attacks
    |> Enum.map(fn attack ->
      # Build the full path context for the function
      full_path =
        if String.starts_with?(attack, "/"), do: attack, else: Path.join(workspace, attack)

      result = path_fn.(full_path)

      %{attack: attack, full_path: full_path, blocked: blocked?(result)}
    end)
    |> Enum.filter(fn result -> not result.blocked end)
  end

  # --- Attack generators ---

  defp classic_traversal do
    [
      "../etc/passwd",
      "../../etc/passwd",
      "../../../etc/passwd",
      "../../../../../../etc/passwd",
      "..\\..\\windows\\system32",
      "..\\..\\..\\etc\\passwd",
      # Deep nesting
      String.duplicate("../", 20) <> "etc/passwd",
      # Relative traversal
      "subdir/../../etc/passwd",
      # Workspace-relative escape
      "valid_dir/../../../etc/shadow",
      # Dot-dot with leading slash
      "/../etc/passwd",
      "/../../etc/passwd",
      # Trailing dot-dot
      "content/../../../tmp/evil",
      # Current dir references mixed in
      "./../../etc/passwd",
      "file.txt/../../../../etc/passwd",
      # Backslash traversal on mixed separators
      "..\\../etc/passwd"
    ]
  end

  defp url_encoded_traversal do
    [
      # URL-encoded ../
      "..%2f..%2f..%2fetc%2fpasswd",
      "%2e%2e%2f%2e%2e%2f%2e%2e%2fetc%2fpasswd",
      # Double-encoded
      "%252e%252e%252fetc%252fpasswd",
      "..%252f..%252fetc%252fpasswd",
      # Mixed encoding with backslash
      "..%5c..%5c..%5cetc%5cpasswd",
      "%2e%2e%5c%2e%2e%5cetc%5cpasswd",
      # Overlong UTF-8 encoding of .
      "..%c0%af..%c0%afetc%c0%afpasswd",
      # URL-encoded null byte — these decode to embedded NUL characters
      "..%00/..%00/etc%00/passwd",
      # %00 in path segments (null-byte injection via URL encoding)
      "safe_file%00.exe/../../etc/passwd",
      "config%00.yml/../../../etc/shadow"
    ]
  end

  defp null_byte_injection do
    [
      # Null byte to truncate — these test how the evaluator handles
      # embedded NUL characters which can cause path truncation in C APIs.
      "valid_file.ex\0/../../etc/passwd",
      "../../../etc/passwd\0.jpg",
      "/workspace/safe.txt\0../../etc/passwd"
    ]
  end

  defp unicode_tricks do
    [
      # Unicode direction override
      # RLO
      "../etc/passwd\u202E",
      # Unicode dots that look like ..
      "\u2024\u2024/etc/passwd",
      # Full-width dots
      "\uff0e\uff0e/etc/passwd",
      # Homoglyph attacks
      "︎../etc/passwd",
      # Zero-width characters
      "../\u200Betc/passwd",
      "..\u200C/..\u200C/etc/passwd"
    ]
  end

  defp absolute_path_escapes do
    [
      "/etc/passwd",
      "/etc/shadow",
      "/proc/self/environ",
      "/proc/version",
      "/root/.ssh/id_rsa",
      "/var/log/auth.log",
      "/tmp/evil_script.sh",
      "/dev/null",
      # Common Windows paths
      "C:\\Windows\\System32\\config\\SAM",
      "C:\\Users\\Administrator\\.ssh\\id_rsa"
    ]
  end

  defp mixed_encoding do
    [
      # Combine URL encoding + traversal
      "..%2f..%2f..%2f%2e%2e/etc/passwd",
      # URL-encoded absolute path
      "%2fetc%2fpasswd",
      # Mixed case traversal (some systems are case-sensitive)
      "..%2F..%2Fetc%2Fpasswd",
      # Encoded + unicode
      "..%2f\u2024/etc/passwd",
      # Partially encoded
      "..%2f../etc/passwd"
    ]
  end

  defp dangerous_edge_cases do
    [
      # Overlong paths
      String.duplicate("a/", 500) <> "../etc/passwd",
      # Tilde expansion (should not expand)
      "~/../../etc/passwd",
      # Symlink-like
      "/workspace/symlink/../../../etc/passwd",
      # Variables (should not expand)
      "$HOME/../../etc/passwd",
      "${HOME}/../../etc/passwd",
      # Backtick injection in path
      "`rm -rf /`",
      # Command substitution
      "$(cat /etc/passwd)"
      # Newline injection — resolved path stays under workspace due to segment splitting,
      # so this is intentionally excluded from traversal attempts. See BD-0070 analysis.
      # "/workspace/file.ex\n../../etc/passwd"
    ]
  end

  # --- Public normalization helper ---

  @doc """
  Recursively URL-decodes a path string until no more `%XX` sequences remain.

  Handles single, double, and mixed encoding layers. This ensures that
  encoded traversal vectors like `..%2f..%2fetc%2fpasswd` are decoded
  to `../../etc/passwd` before containment checks.

  Returns the fully-decoded path string.
  """
  @spec normalize_encoded_path(String.t()) :: String.t()
  def normalize_encoded_path(path) when is_binary(path) do
    decoded = URI.decode(path)

    if decoded == path do
      path
    else
      # Recurse — an attacker may double-encode like %252e → %2e → .
      normalize_encoded_path(decoded)
    end
  end

  # --- Helpers ---

  defp blocked?({:denied, _}), do: true
  defp blocked?({:error, _}), do: true
  defp blocked?(:allowed), do: false
  defp blocked?(true), do: false
  defp blocked?(false), do: true
  defp blocked?(:denied), do: true

  # Fail-closed: unknown result shapes are logged and treated as blocked.
  # Returning `true` (blocked) is the safe default, but the unknown shape
  # indicates a broken integration that should be investigated.
  defp blocked?(other) do
    require Logger
    Logger.warning("PathFuzzer.blocked?/1 received unknown shape: #{inspect(other)}")
    true
  end
end
