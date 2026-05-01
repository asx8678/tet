# 14 — Secrets and Redaction

The original plan redacted secrets before display. That is the wrong
direction: a secret in a file the agent reads is streamed to the LLM
provider in plaintext, even if the CLI hides it from the human's
screen. This doc fixes that and answers "where do API keys live."

> **v0.3 changelog:** keychain integration claim was overstated — there
> is no maintained Elixir library for OS keychains. v0.3 makes
> environment variables the v1 default and ships keychain support as
> an opt-in shell-out adapter, which is honest about the trade-off.
> Pattern-based redaction explicitly framed as best-effort with an
> entropy detector backstop. Placeholder round-trip problem (a patch
> touching a redacted region would corrupt the original file)
> addressed via a patch validator that rejects diffs touching
> redacted regions.

## Threat model

- **Worst case:** an API key, AWS credential, or `.env` value leaks
  to a third-party LLM provider via a `read_file` tool result, then
  ends up in the provider's training data or logs.
- **Bad case:** a secret leaks to the local audit log or a saved
  artifact in `.tet/artifacts/`.
- **Annoying case:** a secret renders to the user's terminal.

The original plan handled only the "annoying case." This doc handles
all three, while being explicit about the limits.

## Credential storage

Provider API keys, MCP tokens, and any other credentials NEVER live in
`.tet/config.toml`. The config references them by name; the runtime
resolves them via `Tet.Secrets`.

```elixir
defmodule Tet.Secrets do
  @callback get(name :: String.t(), context :: map()) ::
    {:ok, String.t()} | {:error, :not_found}
end
```

### Default adapter (v1): environment variables

`Tet.Secrets.Env` reads from the OS environment. Config:

```toml
[providers.anthropic_main]
type = "anthropic"
api_key_env = "ANTHROPIC_API_KEY"
```

The runtime calls `Tet.Secrets.get("ANTHROPIC_API_KEY", %{})`; the env
adapter returns the variable's value. If the variable is unset, the
runtime fails the provider call with `:auth_failed` rather than
crashing.

This is the v1 default because it works on every platform without
extra dependencies. Direct `System.get_env/1` calls for credential
keys are forbidden outside `Tet.Secrets`; enforced by
`tools/check_imports.sh` (the guard greps for known credential
suffixes like `_API_KEY`, `_TOKEN`, `_SECRET` outside the `Tet.Secrets`
module).

### Opt-in adapter (post-v1): OS keychain via shell-out

There is no maintained Elixir library for OS keychains as of v1
planning. The honest path is shelling out to platform-native tools:

| Platform | Binary           | Read command                                    |
| -------- | ---------------- | ----------------------------------------------- |
| Linux    | `secret-tool`    | `secret-tool lookup service dev.tet account <K>`|
| macOS    | `security`       | `security find-generic-password -s dev.tet -a <K> -w` |
| Windows  | `cmdkey` / WCM   | (more complex; PowerShell wrapper)              |

`Tet.Secrets.Keychain` (post-v1, gated on `[secrets].adapter = "keychain"`)
spawns the appropriate binary, scrubs the environment, and reads from
stdout. Output is never logged. If the platform binary is missing or
fails, the runtime falls back to env. `tet doctor` reports which
adapter is in use and whether the platform binary was found.

This is opt-in because shell-out is brittle (locale issues, locked
keyrings, GUI prompts on first access on macOS) and because the
maintenance burden is real. The v1 default of env vars covers the
common case.

### Future adapter slot: external secret manager

`Tet.Secrets` is a behaviour. Adapters for HashiCorp Vault, AWS
Secrets Manager, etc. can ship as separate apps in v2.

### CLI

```text
tet config set-secret <name>      # post-v1; reads stdin (no echo) for keychain
tet config show                   # never prints credential values
```

`tet config show` always renders `api_key_env = "ANTHROPIC_API_KEY"`,
never the value. Even with `--json`.

## Redaction layers

Three independent passes, each with different scope.

> **Honest framing:** all three layers are pattern-based best-effort
> defenses. They reduce blast radius but cannot guarantee zero leaks.
> The right defense in depth is: (a) avoid putting secrets in files
> that the agent reads, (b) use deny-globs (corrections §4) to keep
> the agent out of `priv/secrets/` and similar paths, (c) use
> local-only providers (llama.cpp, Ollama) when handling sensitive
> data.

### Layer 1 — Inbound (file → prompt)

Runs on tool outputs *before* they are added to the conversation
history. This is the layer the original plan was missing.

Patterns:

- Generic `[A-Z0-9_]+_(API_KEY|TOKEN|SECRET)\s*=\s*[^\s]+` and
  `(api[_-]?key|token|secret)\s*[:=]\s*['"]?[A-Za-z0-9._\-]{20,}`.
- Provider-specific: `sk-[A-Za-z0-9]{20,}` (OpenAI),
  `sk-ant-[A-Za-z0-9_\-]{20,}` (Anthropic),
  `csk-[a-z0-9]{20,}` (Cerebras), `AKIA[0-9A-Z]{16}` (AWS),
  `xox[baprs]-[A-Za-z0-9-]{10,}` (Slack).
- PEM blocks: `-----BEGIN [A-Z ]+-----` ... `-----END [A-Z ]+-----`.
- Authorization headers: `Authorization:\s+Bearer .+`,
  `Authorization:\s+Basic .+`.
- Database URLs with passwords: `://[^:]+:[^@]+@` becomes
  `://[user]:[redacted]@`.
- **Entropy backstop**: any token-like string of length ≥ 24 with
  Shannon entropy ≥ 4.0 is flagged as suspicious and replaced with a
  generic placeholder. False positives happen; the entropy threshold
  is configurable.

A redacted value becomes a placeholder of the form
`<redacted:openai_api_key:1>` (kind tag + per-conversation index).
The mapping `placeholder → original` is stored in the workflow journal
so a second tool call returning the same secret produces the same
placeholder.

### Layer 2 — Outbound (logs and audit)

Runs before any log emission or audit write. Same patterns as layer 1
plus:

- Path redaction for paths containing `/.ssh/`, `/secrets/`,
  `/credentials/` (replaced with `<redacted_path>`).
- Tool argument redaction: full argument map serialized through layer
  1 before logging.

### Layer 3 — Display (CLI/LiveView)

The original plan's redaction. Runs last on anything written to
terminal or browser. Conservative — over-redacts rather than under.
Catches anything earlier layers missed; the user's last line of
defense.

## The placeholder round-trip problem

If a tool reads a file, redacts `sk-abc123...` to
`<redacted:openai_api_key:1>`, and the LLM proposes a patch to that
file — the patch will contain the placeholder, not the original. Naive
application would corrupt the file.

**Fix.** `Tet.Patch.validate/2` rejects any diff whose hunks intersect
a region the journal records as redacted within this workflow. The
rejection produces:

- Tool result `:error` with reason `:patch_touches_redacted_region`.
- An `error.recorded` event explaining the redacted lines.
- The agent retries by avoiding those lines (its reasoning sees the
  rejection reason).

Implementation: when layer 1 redacts content from a file, the journal
records `(file_path, byte_offset, byte_length)` per redaction in the
`tool_run:read_file` step's output. The patch validator computes hunk
byte ranges in pre-state and intersects.

This is conservative: a patch that genuinely should touch a redacted
region (e.g., the user is asking the agent to *replace* an API key
with a different one) will fail. The user resolves by either
(a) rotating the key first and re-running, or (b) removing the
file's read from history via `tet truncate`.

## Verifier env scrubbing

Allowlist, not blocklist:

```elixir
@base_env_keys ~w(PATH HOME USER LANG LC_ALL TERM TMPDIR)
@allowed_prefixes ~w(MIX_ NODE_ NPM_ CARGO_ RUST CI)

def verifier_env(workspace_root) do
  System.get_env()
  |> Enum.filter(fn {k, _v} ->
    k in @base_env_keys or
      Enum.any?(@allowed_prefixes, &String.starts_with?(k, &1))
  end)
  |> Enum.into(%{"TET_WORKSPACE" => workspace_root, "PWD" => workspace_root})
end
```

No `*_API_KEY`, `*_TOKEN`, `*_SECRET`, no AWS variables, no
`DATABASE_URL`. Verifiers needing custom variables declare them:

```toml
[verification.allowlist]
mix_test = ["mix", "test"]

[verification.env]
mix_test = ["MIX_ENV"]      # additional vars passed through, never values
```

## Provider request redaction

Before sending to a provider:

- Strip internal metadata (provider-bound payload is messages, model,
  tools, sampling params only).
- Apply layer 1 redaction to every message's content. Yes, even user
  messages — if a user pastes their `.env` into a prompt, we redact.
- Tool result messages get layer 1 redaction.

The `provider_payload` artifact stores the post-redaction payload, so
saved debug payloads cannot leak secrets.

## Audit logging of redaction

```json
{
  "ts": "...",
  "kind": "tool_output_redacted",
  "tool_name": "read_file",
  "patterns": ["openai_api_key", "private_key_pem", "entropy_high"],
  "count": 3,
  "session_id": "..."
}
```

Lets users see when redaction fired without revealing what was
redacted. `tet audit export --filter redaction` filters to these.

## Acceptance

- [ ] `Tet.Secrets` behaviour with env adapter as v1 default.
- [ ] No `System.get_env` calls for credential keys outside
      `Tet.Secrets`. Enforced by `tools/check_imports.sh`.
- [ ] `tet config show` never prints credential values, including in
      `--json` mode.
- [ ] Layer 1 redaction runs in the prompt composer's tool-output
      path and is verified against a corpus of 50+ secret patterns.
- [ ] Layer 1 redaction is idempotent on the same secret across
      multiple tool calls within one workflow (placeholder reuse).
- [ ] Entropy backstop detects high-entropy tokens of length ≥ 24
      with configurable threshold.
- [ ] `Tet.Patch.validate/2` rejects diffs touching redacted regions
      with `:patch_touches_redacted_region`.
- [ ] Verifier env is allowlist-built; tests assert `*_API_KEY` is
      never present.
- [ ] `provider_payload` artifacts post-redaction are scanned for
      secret patterns; zero leaks across the test corpus.
- [ ] Property test: 1000 random files containing planted secrets are
      read; provider payloads contain zero unredacted matches.
- [ ] Keychain adapter is **not** required for v1 acceptance; if
      shipped, `tet doctor` reports the active adapter and platform
      binary status.
