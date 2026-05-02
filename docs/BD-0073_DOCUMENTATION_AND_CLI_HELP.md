# BD-0073: Documentation Set and CLI Help

## Overview

This document describes the TET documentation system and CLI help functionality introduced in BD-0073.

The documentation system provides topic-based documentation accessible via `tet help <topic>` commands. Each topic includes descriptions, related commands, safety warnings, and verification commands.

## Topics

The following 10 documentation topics are available:

| Topic ID     | Title                        | CLI Command              |
|--------------|------------------------------|---------------------------|
| cli          | CLI Usage                    | `tet help cli`            |
| config       | Configuration                | `tet help config`         |
| profiles     | Profiles                     | `tet help profiles`       |
| tools        | Tools & Contracts            | `tet help tools`          |
| mcp          | Model Context Protocol (MCP) | `tet help mcp`            |
| remote       | Remote Operations            | `tet help remote`         |
| repair       | Self-Healing & Repair        | `tet help repair`         |
| security     | Security Policy              | `tet help security`       |
| migration    | Migration                    | `tet help migration`      |
| release      | Release Management           | `tet help release`        |

## Safety Warnings

All topics include safety warnings to alert operators to potential risks. Key warnings across topics include:

- Some CLI commands modify system state — review safety prompts before confirming.
- Sensitive values (API keys, secrets) should use the secrets store, not plain-text config.
- Profiles with broad tool access can execute destructive actions — review before assigning.
- Write-capable tools can modify system state — always review before confirming execution.
- MCP permission gates prevent unsafe tool calls — do not bypass without review.
- Remote operations execute commands on external systems — verify target and credentials.
- Trust boundaries limit what remote sessions can access — review before expanding.
- Patch operations can modify code — always review diffs before applying.
- Rollback restores previous state — verify rollback plan matches current state.
- Security policies restrict agent capabilities — ensure policies do not conflict.
- Redacted data is unrecoverable — confirm redaction rules before enabling.
- Migrations can change persistent data — always backup before applying.
- Rollback is not available for all migration types — verify before applying.
- Releases can affect production systems — all releases require verification.
- Automatic rollback triggers on verification failure — ensure monitors are active.

## Verification Commands

Run these commands to verify the documentation system is working correctly:

```bash
# List all available help topics
tet help

# Show specific topic documentation
tet help config
tet help security
tet help release

# Test that unknown topics return error
tet help does-not-exist

# List all topics with descriptions
tet help topics

# Run the documentation tests
MIX_ENV=test mix test apps/tet_core/test/tet/docs_test.exs
MIX_ENV=test mix test apps/tet_core/test/tet/docs/topic_test.exs
```

## CLI Help Architecture

The CLI help system has three components:

1. **Tet.Docs** (`apps/tet_core/lib/tet/docs.ex`) — Documentation registry providing topic-based lookup, search, and aggregated lists.
2. **Tet.Docs.Topic** (`apps/tet_core/lib/tet/docs/topic.ex`) — Topic struct definition and builder functions for all 10 topics.
3. **Tet.Docs.HelpFormatter** (`apps/tet_cli/lib/tet/cli/help_formatter.ex`) — CLI presentation layer for formatting topics and search results.

## Verification Testing

To verify the complete CLI help integration:

```bash
# Check formatting
mix format --check-formatted

# Compile with warnings as errors
MIX_ENV=test mix compile --warnings-as-errors

# Run docs tests
MIX_ENV=test mix test apps/tet_core/test/tet/docs_test.exs
MIX_ENV=test mix test apps/tet_core/test/tet/docs/topic_test.exs

# Run CLI tests
MIX_ENV=test mix test apps/tet_cli/test/tet_cli_test.exs

# Manual verification
mix run -e 'Tet.CLI.run(["help"])'
mix run -e 'Tet.CLI.run(["help", "config"])'
mix run -e 'Tet.CLI.run(["help", "security"])'
mix run -e 'Tet.CLI.run(["help", "does-not-exist"])'
```
