# 13 — Operations, Telemetry, and Multi-Node

> **v0.3 changelog:** dropped the Bandit/Prometheus exporter — adding
> an HTTP server to a project whose entire architecture forbids one in
> the standalone closure was the wrong move. Metrics are emitted as
> `:telemetry` events; export is the operator's choice (file logger,
> StatsD via UDP, or a sidecar). Multi-node story rewritten: 30s polling
> was a textbook double-execution race. Replaced with explicit
> Postgres-advisory-lock claim, gated to `tet_web` only, and demoted
> from "v1 acceptance" to "v1.x design target."

## Telemetry events

All events namespaced under `[:tet, ...]`. Every event includes
`session_id` and `workflow_id` in metadata when applicable.

### Provider

```text
[:tet, :provider, :request, :start]   measurements: %{system_time}
[:tet, :provider, :request, :stop]    measurements: %{duration, input_tokens, output_tokens}
[:tet, :provider, :request, :error]   measurements: %{duration} meta: %{kind}
[:tet, :provider, :stream, :delta]    measurements: %{bytes, deltas}
[:tet, :provider, :retry]             meta: %{attempt, kind, retry_after_ms}
```

### Tools

```text
[:tet, :tool, :run, :start]           meta: %{tool_name, mode}
[:tet, :tool, :run, :stop]            measurements: %{duration} meta: %{result}
[:tet, :tool, :blocked]               meta: %{tool_name, reason}
```

### Workflow

```text
[:tet, :workflow, :step, :start]      meta: %{step_name}
[:tet, :workflow, :step, :commit]     measurements: %{duration} meta: %{step_name}
[:tet, :workflow, :step, :fail]       meta: %{step_name, reason}
[:tet, :workflow, :resumed]           meta: %{recovered_from_step}
[:tet, :workflow, :cancelled]         meta: %{reason}
```

### Patch and verifier

```text
[:tet, :patch, :proposed]             measurements: %{bytes, files}
[:tet, :patch, :applied]              measurements: %{duration, files}
[:tet, :patch, :rolled_back]          meta: %{reason}
[:tet, :verifier, :run, :start]       meta: %{name}
[:tet, :verifier, :run, :stop]        measurements: %{duration, exit_status}
```

### Storage

```text
[:tet, :store, :query]                measurements: %{duration} meta: %{op, adapter}
[:tet, :store, :error]                meta: %{op, kind}
```

## Metrics export

`:telemetry` events carry the data. Tet does **not** ship an HTTP
metrics endpoint in the standalone release — that would contradict the
release closure ban on Plug/Cowboy/Bandit. Operators have three options
in v1, none requiring runtime changes:

1. **stdout/JSON logs** via `Tet.Telemetry.LogHandler` (default in
   `tet_standalone`). Telemetry events become structured log entries.
   Aggregators tail the log.
2. **StatsD over UDP** via an opt-in
   `Tet.Telemetry.StatsdHandler` (post-v1; tiny adapter, no HTTP). UDP
   keeps the standalone closure clean.
3. **External sidecar** (`vector`, `fluent-bit`, `promtail`, etc.)
   reading the JSON log and exporting to whatever store the operator
   prefers.

`tet_web` deployments may add a Prometheus scrape endpoint via the web
app's existing Plug/Cowboy stack — that's allowed because the web app
already pulls in the framework.

## Log schema

Logs are structured. Default formatter (`Tet.Log.Formatter`) produces
JSON in production releases and human-readable in dev. Every log line
carries:

```json
{
  "ts": "2026-04-29T13:35:21.421Z",
  "level": "info",
  "msg": "patch.applied",
  "session_id": "01HW...",
  "workflow_id": "01HW...",
  "step": "patch_apply",
  "duration_ms": 142,
  "files": 3
}
```

Logs are NOT the audit trail — the journal is. Logs are best-effort
observability.

## Audit log vs. user event timeline

Two streams in the same store:

- **User event timeline** (`Tet.list_events/2`) — what the user sees
  in `tet events tail` and the LiveView. Includes
  `provider.text_delta`, approvals, tool runs, etc.
- **Audit log** (`tet_audit` table) — what an operator or auditor
  sees. Includes every provider attempt with redacted payload
  reference, every blocked tool with reason, every workflow recovery,
  every config change, every trust state change.

Audit log is append-only at the application level (no update/delete
API). `tet audit export` writes to a JSONL file for external retention.

## Doctor schema-version check

`tet doctor` adds a schema-version probe:

```text
checking schema version...
  expected: 7
  actual:   5
  ✗ schema is behind code; run: tet migrate
```

`tet migrate` applies pending migrations and emits a
`workspace.migrated` audit entry. Migrations are forward-only in v1; a
schema downgrade requires restoring `.tet/tet.sqlite` from backup.

## Hot upgrades

The original plan was silent. The decision: **v1 does not support hot
code upgrades.** Releases are restart-only.

Reasoning:

1. The durable execution layer (doc 12) makes restart cheap: pending
   workflows resume automatically, approvals survive process death,
   no in-memory state is authoritative.
2. `appup`/`relup` carry significant ongoing cost: every GenServer
   needs a `code_change/3`, every state change across versions needs
   a migration script, and acceptance gates must verify upgrades from
   every prior version.
3. The benefit (zero-downtime upgrades for a single-node CLI) is small.

This decision is reversible. The durable journal makes a future
hot-upgrade story strictly easier than it would have been without
doc 12.

For `tet_web` running as a multi-tenant service, blue-green deployment
behind a load balancer is the recommended pattern.

## Multi-node — v1.x design target, not v1

`tet_standalone` is single-node by design. `tet_web` *may* be deployed
multi-node post-v1, but the v1 acceptance criteria do not include
multi-node correctness. This is now an explicit non-goal of v1.

The design target for when it ships:

### Storage

Postgres only (`tet_store_postgres`). SQLite single-writer semantics
break multi-node.

### Workflow ownership via Postgres advisory lock

The v0.2 doc proposed "30s polling" for failover. That is a
double-execution race: two nodes can both see a workflow as available
and both start an executor. The fix is a deterministic claim:

```sql
SELECT pg_try_advisory_xact_lock(hashtext('tet:workflow:' || $1)) AS claimed;
```

The store's `claim_workflow/3` (doc 12 store contract) returns
`{:ok, :claimed}` only when the lock acquires. Other nodes get
`{:error, :held_by, <node_atom>}` and skip. Locks are released on
transaction commit (after every step commit) and on connection death,
so a crashed node releases its claims at TCP teardown.

On planned shutdown, each node walks its active workflows, releases
claims, and emits `workflow.released_for_failover` events.

### Event bus across nodes

`tet_runtime` publishes through `Tet.EventBus`, which is pluggable.
Single-node uses `Registry`. Multi-node uses `:pg` (process groups,
which work across an Erlang cluster) or — when `tet_web_phoenix` is
present — Phoenix.PubSub-on-Postgres. The runtime does not depend on
either; the bus implementation is configured at release time.

### Approval state

Stored in Postgres; any node can serve the approval UI. Approving
publishes a `workflow.resume_requested` event; the owning node (or
the next to claim) consumes it.

### v1 vs v1.x

| Concern                              | v1 must-have | v1.x |
| ------------------------------------ | :----------: | :--: |
| Single-node `tet_standalone` works   | yes          |      |
| Single-node `tet_web` works          | yes          |      |
| Multi-node `tet_web` correctness     |              | yes  |
| Postgres advisory-lock claim         |              | yes  |
| `:pg`-backed `Tet.EventBus`          |              | yes  |

The `Tet.EventBus` interface and the `claim_workflow/3` store
callback exist in v1 (single-node implementations are trivial), so
adding multi-node is additive rather than disruptive.

## Privacy and data flow

Borrowed from Code Puppy's stance, made explicit:

- Tet emits no telemetry to Anthropic or anywhere else by default.
- Provider API calls go directly to the provider the user configured.
- Local-only configuration (`base_url = "http://localhost:8080/v1"`
  for llama.cpp/vLLM/Ollama) means zero outbound network from the
  runtime.
- The audit log stays in the workspace's `.tet/tet.sqlite` unless
  explicitly exported.

`tet doctor --network` reports every outbound endpoint the current
configuration would contact, so users can audit data flow before
sending their first prompt.

## Acceptance

- [ ] All telemetry events listed above are emitted at the named
      points and covered by `:telemetry_test` assertions.
- [ ] Default log formatter produces structured JSON in prod, human in
      dev.
- [ ] Audit log records: every blocked tool, trust state change,
      config change, workflow recovery, provider attempt.
- [ ] `tet doctor` prints schema version and refuses to start on
      mismatch.
- [ ] `tet doctor --network` enumerates outbound endpoints.
- [ ] `tet audit export` produces JSONL with stable schema.
- [ ] `tet_standalone` release closure check still passes; no Bandit
      or Plug or Cowboy or Phoenix in standalone.
- [ ] Multi-node design (advisory locks, pg event bus) is documented
      but **not** required for v1 acceptance.
