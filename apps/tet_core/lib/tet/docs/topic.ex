defmodule Tet.Docs.Topic do
  @moduledoc """
  A documentation topic struct — BD-0073.

  Each topic bundles a title, descriptive content, related CLI commands,
  safety warnings, and verification commands into a single struct.
  """

  @topics [
    :cli,
    :config,
    :profiles,
    :tools,
    :mcp,
    :remote,
    :repair,
    :security,
    :migration,
    :release
  ]

  defstruct [:id, :title, :content, :related_commands, :safety_warnings, :verification_commands]

  @type t :: %__MODULE__{
          id: atom(),
          title: String.t(),
          content: String.t(),
          related_commands: [String.t()],
          safety_warnings: [String.t()],
          verification_commands: [String.t()]
        }

  @doc "Returns the canonical list of all topic IDs."
  @spec topics() :: [atom()]
  def topics, do: @topics

  @doc """
  Returns a map of string topic names to atom topic IDs.

  Use this for safe string-to-atom lookup without String.to_atom/1.
  """
  @spec string_to_id() :: %{String.t() => atom()}
  def string_to_id do
    @topics
    |> Enum.map(fn id -> {Atom.to_string(id), id} end)
    |> Map.new()
  end

  @doc """
  Looks up a topic by its string name, returning {:ok, topic_id} or :error.

  This is the safe alternative to String.to_atom/1 for user-provided strings.
  """
  @spec lookup(String.t()) :: {:ok, atom()} | :error
  def lookup(name) when is_binary(name) do
    case Map.get(string_to_id(), name) do
      nil -> :error
      id -> {:ok, id}
    end
  end

  @doc """
  Builds a list of all topic structs with their full content.
  """
  @spec build_all() :: [t()]
  def build_all do
    Enum.map(@topics, &build/1)
  end

  @doc """
  Builds a single topic struct by ID.
  """
  @spec build(atom()) :: t()
  def build(:cli) do
    %__MODULE__{
      id: :cli,
      title: "CLI Usage",
      content:
        "The `tet` command-line interface provides access to all TET platform features. " <>
          "Commands follow a `tet <domain> <action> [options]` pattern. " <>
          "Use `tet help` for a command overview and `tet help <topic>` for detailed guidance.",
      related_commands: ["tet help", "tet help <topic>", "tet --version", "tet --help"],
      safety_warnings: [
        "Some CLI commands modify system state — review safety prompts before confirming."
      ],
      verification_commands: ["tet help", "tet help config", "tet help tools"]
    }
  end

  def build(:config) do
    %__MODULE__{
      id: :config,
      title: "Configuration",
      content:
        "TET is configured via `tet.config.toml` or environment variables. " <>
          "Key sections include: profiles, providers, remote endpoints, and tool permissions. " <>
          "Configuration is validated at startup via `tet doctor` — invalid settings produce clear diagnostics.\n\n" <>
          "[Planned] Future CLI commands: `tet config init`, `tet config validate`, `tet config show`, `tet config set <key> <value>`",
      related_commands: [
        "tet doctor",
        "mix test apps/tet_core/test/tet/security_policy_test.exs"
      ],
      safety_warnings: [
        "Sensitive values (API keys, secrets) should use the secrets store, not plain-text config."
      ],
      verification_commands: [
        "tet doctor",
        "mix test apps/tet_core/test/tet/security_policy_test.exs"
      ]
    }
  end

  def build(:profiles) do
    %__MODULE__{
      id: :profiles,
      title: "Profiles",
      content:
        "Profiles define role-based behaviour for TET agents. Each profile specifies a model, " <>
          "capabilities, tool access, and safety constraints. Profiles live in the profile registry " <>
          "and are loaded by name at session start.",
      related_commands: [
        "tet profiles",
        "tet profile show <name>"
      ],
      safety_warnings: [
        "Profiles with broad tool access can execute destructive actions — review before assigning."
      ],
      verification_commands: ["tet profiles", "tet profile show chat"]
    }
  end

  def build(:tools) do
    %__MODULE__{
      id: :tools,
      title: "Tools & Contracts",
      content:
        "Tools are the atomic capabilities TET agents can invoke. Each tool has a contract " <>
          "specifying its schema, read/write classification, and safety level. The tool registry " <>
          "manages tool discovery, and read-only contracts provide safety guarantees.\n\n" <>
          "[Planned] Future CLI commands: `tet tool list`, `tet tool show <name>`, `tet tool contract <name>`",
      related_commands: ["mix test apps/tet_core/test/tet/tool_contract_test.exs"],
      safety_warnings: [
        "Write-capable tools can modify system state — always review before confirming execution."
      ],
      verification_commands: ["mix test apps/tet_core/test/tet/tool_contract_test.exs"]
    }
  end

  def build(:mcp) do
    %__MODULE__{
      id: :mcp,
      title: "Model Context Protocol (MCP)",
      content:
        "MCP defines how TET agents communicate with language models. It includes call policies, " <>
          "permission gates, tool classification, and server orchestration. MCP ensures safe, " <>
          "auditable model interactions with clear permission boundaries.\n\n" <>
          "[Planned] Future CLI commands: `tet mcp status`, `tet mcp call <tool>`, `tet mcp policy show`",
      related_commands: ["mix test apps/tet_core/test/tet/mcp"],
      safety_warnings: [
        "MCP permission gates prevent unsafe tool calls — do not bypass without review."
      ],
      verification_commands: ["mix test apps/tet_core/test/tet/mcp"]
    }
  end

  def build(:remote) do
    %__MODULE__{
      id: :remote,
      title: "Remote Operations",
      content:
        "TET supports remote operation over SSH with configurable trust boundaries and " <>
          "environment policies. Remote profiles define target hosts, authentication, and " <>
          "allowed operations. Policy parity gates ensure local and remote policies remain consistent.\n\n" <>
          "[Planned] Future CLI commands: `tet remote connect <profile>`, `tet remote list`, `tet remote profile show <name>`, `tet remote parity check`",
      related_commands: ["mix test apps/tet_core/test/tet/remote"],
      safety_warnings: [
        "Remote operations execute commands on external systems — verify target and credentials.",
        "Trust boundaries limit what remote sessions can access — review before expanding."
      ],
      verification_commands: ["mix test apps/tet_core/test/tet/remote"]
    }
  end

  def build(:repair) do
    %__MODULE__{
      id: :repair,
      title: "Self-Healing & Repair",
      content:
        "TET's repair system detects failures and applies automated recovery strategies. " <>
          "Strategies include retry, fallback, patch application, and human escalation. " <>
          "The patch workflow and safe release pipeline provide structured rollback and verification.\n\n" <>
          "[Planned] Future CLI commands: `tet repair status`, `tet repair log`, `tet repair retry <id>`, `tet safe-release start`, `tet safe-release verify`",
      related_commands: ["mix test apps/tet_core/test/tet/repair"],
      safety_warnings: [
        "Patch operations can modify code — always review diffs before applying.",
        "Rollback restores previous state — verify rollback plan matches current state."
      ],
      verification_commands: ["mix test apps/tet_core/test/tet/repair"]
    }
  end

  def build(:security) do
    %__MODULE__{
      id: :security,
      title: "Security Policy",
      content:
        "TET enforces security policies at multiple layers: redaction of sensitive data, " <>
          "secret pattern detection, shell policy artifacts, and security policy evaluation. " <>
          "Policies are composable and can be applied per-profile or per-session.\n\n" <>
          "[Planned] Future CLI commands: `tet security policy list`, `tet security policy show <name>`, `tet security eval`, `tet secrets scan`",
      related_commands: ["mix test apps/tet_core/test/tet/security_policy_test.exs"],
      safety_warnings: [
        "Security policies restrict agent capabilities — ensure policies do not conflict.",
        "Redacted data is unrecoverable — confirm redaction rules before enabling."
      ],
      verification_commands: ["mix test apps/tet_core/test/tet/security_policy_test.exs"]
    }
  end

  def build(:migration) do
    %__MODULE__{
      id: :migration,
      title: "Migration",
      content:
        "Migration tooling handles upgrading TET configurations, profiles, and data stores " <>
          "between versions. Migrations are versioned and reversible when possible.\n\n" <>
          "[Planned] Future CLI commands: `tet migration plan`, `tet migration apply`, `tet migration rollback`, `tet migration status`",
      related_commands: ["mix test apps/tet_core/test/tet/security_policy_test.exs"],
      safety_warnings: [
        "Migrations can change persistent data — always backup before applying.",
        "Rollback is not available for all migration types — verify before applying."
      ],
      verification_commands: ["mix test apps/tet_core/test/tet/security_policy_test.exs"]
    }
  end

  def build(:release) do
    %__MODULE__{
      id: :release,
      title: "Release Management",
      content:
        "Safe release management provides structured workflows for deploying changes. " <>
          "The safe release pipeline includes verification gates, automatic rollback triggers, " <>
          "and audit logging. Releases are tracked and can be approved or rejected.\n\n" <>
          "[Planned] Future CLI commands: `tet release start`, `tet release status`, `tet release approve <id>`, `tet release reject <id>`, `tet release rollback <id>`\n\n" <>
          "== Release Recovery Runbook ==\n\n" <>
          "1. DETECT FAILED STATE:\n" <>
          "   Run `tools/check_release_closure.sh --no-build` to verify release closure.\n" <>
          "   Run `mix standalone.check` to verify standalone build integrity.\n" <>
          "   Check for failing tests: `mix test`\n" <>
          "   Check for compilation warnings: `mix compile --warnings-as-errors`\n" <>
          "\n" <>
          "2. SAFETY CHECKS BEFORE ROLLBACK:\n" <>
          "   - ⚠  Ensure no in-progress sessions will be corrupted.\n" <>
          "   - ⚠  Verify rollback target is a known-good commit or release tag.\n" <>
          "   - ⚠  Confirm you have a backup of the current store if data migration was run.\n" <>
          "   - ⚠  Notify team members who may be relying on the current release.\n" <>
          "\n" <>
          "3. RECOVERY COMMANDS:\n" <>
          "   git checkout <last-known-good-tag>\n" <>
          "   mix deps.get\n" <>
          "   mix compile --warnings-as-errors\n" <>
          "   mix test\n" <>
          "   MIX_ENV=prod mix release\n" <>
          "\n" <>
          "4. POST-RECOVERY VERIFICATION:\n" <>
          "   - Run `tet doctor` and confirm all checks pass.\n" <>
          "   - Run `tools/check_release_closure.sh --no-build` to confirm closure.\n" <>
          "   - Run `mix test` and confirm all tests pass.\n" <>
          "   - Verify known working profiles: `tet profiles`, `tet profile show chat`\n" <>
          "   - Send a test message: `tet ask --session recovery-test 'hello'`",
      related_commands: [
        "tools/check_release_closure.sh --no-build",
        "mix standalone.check",
        "tet doctor",
        "tet profiles",
        "tet profile show chat"
      ],
      safety_warnings: [
        "Releases can affect production systems — all releases require verification.",
        "Automatic rollback triggers on verification failure — ensure monitors are active.",
        "⚠  Before rollback: backup store data, verify target commit, and notify the team."
      ],
      verification_commands: [
        "tools/check_release_closure.sh --no-build",
        "mix standalone.check",
        "tet doctor",
        "mix test"
      ]
    }
  end
end
