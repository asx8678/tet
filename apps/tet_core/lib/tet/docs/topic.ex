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
          "Configuration is validated at startup — invalid settings produce clear diagnostics.",
      related_commands: [
        "tet config init",
        "tet config validate",
        "tet config show",
        "tet config set <key> <value>"
      ],
      safety_warnings: [
        "Sensitive values (API keys, secrets) should use the secrets store, not plain-text config."
      ],
      verification_commands: ["tet config validate", "tet config show"]
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
        "tet profile list",
        "tet profile show <name>",
        "tet profile create",
        "tet profile validate"
      ],
      safety_warnings: [
        "Profiles with broad tool access can execute destructive actions — review before assigning."
      ],
      verification_commands: ["tet profile list", "tet profile validate --all"]
    }
  end

  def build(:tools) do
    %__MODULE__{
      id: :tools,
      title: "Tools & Contracts",
      content:
        "Tools are the atomic capabilities TET agents can invoke. Each tool has a contract " <>
          "specifying its schema, read/write classification, and safety level. The tool registry " <>
          "manages tool discovery, and read-only contracts provide safety guarantees.",
      related_commands: ["tet tool list", "tet tool show <name>", "tet tool contract <name>"],
      safety_warnings: [
        "Write-capable tools can modify system state — always review before confirming execution."
      ],
      verification_commands: ["tet tool list", "tet tool contract --all"]
    }
  end

  def build(:mcp) do
    %__MODULE__{
      id: :mcp,
      title: "Model Context Protocol (MCP)",
      content:
        "MCP defines how TET agents communicate with language models. It includes call policies, " <>
          "permission gates, tool classification, and server orchestration. MCP ensures safe, " <>
          "auditable model interactions with clear permission boundaries.",
      related_commands: ["tet mcp status", "tet mcp call <tool>", "tet mcp policy show"],
      safety_warnings: [
        "MCP permission gates prevent unsafe tool calls — do not bypass without review."
      ],
      verification_commands: ["tet mcp status", "tet mcp policy show"]
    }
  end

  def build(:remote) do
    %__MODULE__{
      id: :remote,
      title: "Remote Operations",
      content:
        "TET supports remote operation over SSH with configurable trust boundaries and " <>
          "environment policies. Remote profiles define target hosts, authentication, and " <>
          "allowed operations. Policy parity gates ensure local and remote policies remain consistent.",
      related_commands: [
        "tet remote connect <profile>",
        "tet remote list",
        "tet remote profile show <name>",
        "tet remote parity check"
      ],
      safety_warnings: [
        "Remote operations execute commands on external systems — verify target and credentials.",
        "Trust boundaries limit what remote sessions can access — review before expanding."
      ],
      verification_commands: ["tet remote list", "tet remote parity check"]
    }
  end

  def build(:repair) do
    %__MODULE__{
      id: :repair,
      title: "Self-Healing & Repair",
      content:
        "TET's repair system detects failures and applies automated recovery strategies. " <>
          "Strategies include retry, fallback, patch application, and human escalation. " <>
          "The patch workflow and safe release pipeline provide structured rollback and verification.",
      related_commands: [
        "tet repair status",
        "tet repair log",
        "tet repair retry <id>",
        "tet safe-release start",
        "tet safe-release verify"
      ],
      safety_warnings: [
        "Patch operations can modify code — always review diffs before applying.",
        "Rollback restores previous state — verify rollback plan matches current state."
      ],
      verification_commands: ["tet repair status", "tet repair log --recent 10"]
    }
  end

  def build(:security) do
    %__MODULE__{
      id: :security,
      title: "Security Policy",
      content:
        "TET enforces security policies at multiple layers: redaction of sensitive data, " <>
          "secret pattern detection, shell policy artifacts, and security policy evaluation. " <>
          "Policies are composable and can be applied per-profile or per-session.",
      related_commands: [
        "tet security policy list",
        "tet security policy show <name>",
        "tet security eval",
        "tet secrets scan"
      ],
      safety_warnings: [
        "Security policies restrict agent capabilities — ensure policies do not conflict.",
        "Redacted data is unrecoverable — confirm redaction rules before enabling."
      ],
      verification_commands: ["tet security policy list", "tet security eval --all"]
    }
  end

  def build(:migration) do
    %__MODULE__{
      id: :migration,
      title: "Migration",
      content:
        "Migration tooling handles upgrading TET configurations, profiles, and data stores " <>
          "between versions. Migrations are versioned and reversible when possible. " <>
          "Run `tet migration plan` before any migration to review the impact.",
      related_commands: [
        "tet migration plan",
        "tet migration apply",
        "tet migration rollback",
        "tet migration status"
      ],
      safety_warnings: [
        "Migrations can change persistent data — always backup before applying.",
        "Rollback is not available for all migration types — verify before applying."
      ],
      verification_commands: ["tet migration plan", "tet migration status"]
    }
  end

  def build(:release) do
    %__MODULE__{
      id: :release,
      title: "Release Management",
      content:
        "Safe release management provides structured workflows for deploying changes. " <>
          "The safe release pipeline includes verification gates, automatic rollback triggers, " <>
          "and audit logging. Releases are tracked and can be approved or rejected.",
      related_commands: [
        "tet release start",
        "tet release status",
        "tet release approve <id>",
        "tet release reject <id>",
        "tet release rollback <id>"
      ],
      safety_warnings: [
        "Releases can affect production systems — all releases require verification.",
        "Automatic rollback triggers on verification failure — ensure monitors are active."
      ],
      verification_commands: ["tet release status", "tet release verify <id>"]
    }
  end
end
