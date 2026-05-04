# BD-0037: Retention and Audit Policy

**Phase:** 10 — State, memory, artifacts, and checkpoints
**Status:** Implemented
**Module:** `Tet.Retention` (`apps/tet_core/lib/tet/retention/`)

---

## Overview

This document defines the data retention lifecycle for TET: how long data is kept,
what happens when it expires, and the hard safety rules that prevent silent deletion
of audit-critical records.

Retention is a first-class concern, not an afterthought. Every piece of data in the
system belongs to a **retention class** that governs its TTL, maximum count, and
whether it can ever be automatically pruned.

---

## Retention Classes

The system defines **four** retention classes. Each class carries a default TTL
(time-to-live), a maximum record count, and an `audit_protected?` flag.

### `:transient` — Throwaway data

| Property         | Default         |
|------------------|-----------------|
| TTL              | 24 hours        |
| Max count        | 1,000           |
| Audit protected  | No              |

**What lives here:** Debug output, temporary tool artifacts, ephemeral session
scratch data, checkpoint snapshots during active work.

**Deletion behavior:** Automatic. Records expire after TTL or when count exceeds
the limit (oldest-first eviction). No human approval required.

**Rationale:** This is the "napkin" tier. If something here disappears mid-session,
nobody cares. Aggressive cleanup keeps storage footprint small.

---

### `:normal` — Operational data

| Property         | Default          |
|------------------|------------------|
| TTL              | 30 days          |
| Max count        | 10,000           |
| Audit protected  | No               |

**What lives here:** Routine artifacts (generated code, diffs, patches), general
events, session checkpoints after the session ends.

**Deletion behavior:** Automatic. Records expire after TTL or when count exceeds
the limit. Still no human approval required, but the longer TTL gives operators
time to notice if something important slipped into this class.

**Rationale:** The "filing cabinet" tier. Useful for a while, not forever. The
30-day window is generous enough for most debugging and reference needs.

---

### `:audit_critical` — Compliance and audit trail

| Property         | Default          |
|------------------|------------------|
| TTL              | 1 year           |
| Max count        | Unlimited        |
| Audit protected  | **Yes**          |

**What lives here:** Approval lifecycle events, workflow step records, error logs,
repair records, general event logs, workflow records.

**Deletion behavior:** **Never auto-deleted.** The enforcer returns an empty list
when asked to find expired audit-critical records. Deletion requires:
1. Explicit acknowledgement via a signed token (HMAC-SHA256)
2. A human operator (or automated process with operator credentials) to generate
   and present the token
3. The record ID, data type, and actor identity are encoded in the token

**Rationale:** These records are the evidence trail. If an approval happened, if an
error occurred, if a workflow step ran — that history must survive. The 1-year TTL
is a **soft cap** for reporting purposes; the `audit_protected?` flag is what
actually prevents deletion.

---

### `:permanent` — Forever records

| Property         | Default          |
|------------------|------------------|
| TTL              | None (infinite)  |
| Max count        | Unlimited        |
| Audit protected  | **Yes**          |

**What lives here:** Approval records with terminal status (approved/rejected),
resolved error logs with repair correlation, any record that represents a
completed human decision.

**Deletion behavior:** **Impossible through the retention system.** The enforcer
returns `{:error, :permanent}` for any deletion attempt. Removal requires direct
database operator action outside the automatic retention pipeline.

**Rationale:** Terminal approval records are the atomic unit of accountability.
They can never be re-created, so they can never be deleted by policy.

---

## Data Type → Class Mapping

Each data type in the system is mapped to a retention class. This mapping is
configurable but the safety invariants are **not**.

| Data Type        | Default Class       | Audit Protected | Notes                              |
|------------------|---------------------|-----------------|------------------------------------|
| `event_log`      | `:audit_critical`   | Yes             | All events are audit trail material |
| `approval`       | `:permanent`        | Yes             | Terminal decisions are forever      |
| `artifact`       | `:normal`           | No              | Generated code, diffs, patches      |
| `checkpoint`     | `:transient`        | No              | Session snapshots, temp state       |
| `error_log`      | `:audit_critical`   | Yes             | Errors are compliance evidence      |
| `repair`         | `:audit_critical`   | Yes             | Repair actions are auditable        |
| `workflow`       | `:audit_critical`   | Yes             | Workflow definitions are tracked    |
| `workflow_step`  | `:audit_critical`   | Yes             | Step execution history              |

### Mapping overrides

Operators can remap data types to different classes via configuration:

```elixir
config :tet_core, Tet.Retention.Policy,
  overrides: [
    checkpoint: :normal  # keep checkpoints for 30 days instead of 24 hours
  ]
```

**Hard rule:** You can remap non-critical types freely. You **cannot** remap an
audit-critical data type (`event_log`, `approval`, `error_log`, `repair`,
`workflow`, `workflow_step`) to a non-protected class. The system rejects this
with `{:error, {:cannot_unprotect_audit_critical_type, data_type}}`.

---

## Safety Rules

These are the non-negotiable invariants enforced by the code. They are tested
in `policy_test.exs` (safety invariants describe block) and cannot be bypassed
through configuration.

### Rule 1: Audit-critical records cannot be silently deleted

The `:audit_critical` and `:permanent` classes both have `audit_protected?: true`.
The enforcer **never** returns audit-protected records from `expired_records/3`.
The `enforce/4` function returns `{:ok, 0}` for audit-protected data types without
even scanning the store.

### Rule 2: Permanent records cannot be deleted through the retention system

`check_before_delete/3` returns `{:error, :permanent}`. `acknowledge_delete/4`
returns `{:error, :permanent}`. There is no code path that allows automatic
deletion of permanent records.

### Rule 3: Audit-critical deletion requires a signed acknowledgement token

To delete an `:audit_critical` record (not permanent), the caller must:
1. Call `acknowledge_delete/4` to generate an HMAC-signed token
2. Present that token to `acknowledged_delete/4`
3. The token encodes: nonce, timestamp, actor identity, class name, and record ID
4. Tokens are non-replayable (random nonce per token)
5. Tokens are non-forgeable (HMAC-SHA256 with per-boot secret, or configured secret)

This two-step flow ensures a human (or authorized process) explicitly acknowledges
the audit implications before deletion proceeds.

### Rule 4: Safety invariants cannot be overridden by configuration

The `Policy` module enforces these at construction time:
- `:audit_critical` class must have `audit_protected?: true` — you cannot set it
  to `false`
- `:permanent` class must have `audit_protected?: true` — same protection
- Audit-critical data types cannot be remapped to unprotected classes

```elixir
# This fails with {:error, {:class_must_be_audit_protected, :audit_critical}}
Policy.new(classes: [audit_critical: [audit_protected?: false]])

# This fails with {:error, {:cannot_unprotect_audit_critical_type, :event_log}}
Policy.new(overrides: [event_log: :normal])
```

### Rule 5: Retention enforcement is non-blocking

`enforce/4` accepts store adapter functions and runs as a background operation.
It never locks the store or blocks main application operations. The caller
provides `store_fun` and `delete_fun` callbacks, making it possible to run
enforcement in a scheduled task, GenServer, or Oban job without coupling to
specific storage implementations.

---

## Configuration

### Class overrides

Override TTL and max count per class:

```elixir
config :tet_core, Tet.Retention.Policy,
  classes: [
    transient: [ttl_seconds: 3600, max_count: 500],       # 1 hour, 500 records
    normal: [ttl_seconds: 604_800],                        # 7 days
    audit_critical: [ttl_seconds: 63_072_000],             # 2 years
    permanent: []                                          # defaults, untouchable
  ]
```

### Data type overrides

Remap data types to different classes:

```elixir
config :tet_core, Tet.Retention.Policy,
  overrides: [
    checkpoint: :normal,       # checkpoints get 30-day retention
    artifact: :transient       # artifacts cleaned up after 24 hours
  ]
```

### Acknowledgement secret

Configure the HMAC secret for ack tokens (default: per-boot random):

```elixir
config :tet_core, Tet.Retention.Policy,
  ack_secret: "your-persistent-secret-here"
```

Without a persistent secret, tokens are invalidated on process restart.

### Programmatic construction

```elixir
{:ok, policy} = Tet.Retention.Policy.new(
  classes: [
    transient: [ttl_seconds: 1800, max_count: 200]
  ],
  overrides: [
    checkpoint: :normal
  ],
  metadata: %{owner: "ops_team"}
)
```

---

## Enforcement Lifecycle

### 1. Eligibility check

Before any deletion, call `check_before_delete/3`:

```elixir
Tet.Retention.Enforcer.check_before_delete(policy, :checkpoint, "cp_001")
# => :ok

Tet.Retention.Enforcer.check_before_delete(policy, :error_log, "err_001")
# => {:error, :audit_protected}

Tet.Retention.Enforcer.check_before_delete(policy, :approval, "ap_001")
# => {:error, :permanent}
```

### 2. Expired record discovery

`expired_records/3` scans a list of records and returns those eligible for
deletion. Audit-protected records are **never** returned:

```elixir
records = [
  %{id: "old", created_at: ~U[2020-01-01 00:00:00Z]},
  %{id: "new", created_at: ~U[2030-01-01 00:00:00Z]}
]

Tet.Retention.Enforcer.expired_records(policy, :checkpoint, records)
# => {:ok, [%{id: "old", created_at: ~U[2020-01-01 00:00:00Z]}]}
```

Records are expired by two mechanisms:
- **TTL-based:** Record's `created_at` is older than `now - ttl_seconds`
- **Count-based:** Total records exceed `max_count`, oldest are evicted

Both mechanisms are applied in order: TTL-expired records are removed first,
then count-based eviction on the remainder.

### 3. Audit-protected deletion (two-step)

```elixir
# Step 1: Generate acknowledgement token
{:ok, token} = Tet.Retention.Enforcer.acknowledge_delete(
  policy, :error_log, "err_001", actor: "ops_user"
)

# Step 2: Present token to complete deletion eligibility
Tet.Retention.Enforcer.acknowledged_delete(policy, :error_log, "err_001", token)
# => :ok
```

### 4. Bulk enforcement

`enforce/4` runs the full lifecycle for a data type:

```elixir
Tet.Retention.Enforcer.enforce(policy, store, :checkpoint,
  store_fun: fn store, session_id, _opts ->
    Tet.Store.list(store, :checkpoint, session_id: session_id)
  end,
  delete_fun: fn store, id, _opts ->
    Tet.Store.delete(store, :checkpoint, id)
  end,
  session_id: "session_123"
)
# => {:ok, deleted_count}
```

The function accepts injected store/delete callbacks to remain storage-agnostic.

### 5. Human-readable description

`describe/2` produces a summary for any data type:

```elixir
Tet.Retention.Enforcer.describe(policy, :checkpoint)
# => "checkpoint → transient: TTL=86400s, max_count=1000, auto-deletable"

Tet.Retention.Enforcer.describe(policy, :approval)
# => "approval → permanent: no TTL, unlimited count, audit-protected"
```

---

## Dry-Run and Export

The retention system supports pre-deletion analysis without side effects:

- **Dry-run:** Call `expired_records/3` to see what *would* be deleted without
  actually deleting anything. This is the default behavior — the function is
  pure and returns data, it does not mutate the store.

- **Export before deletion:** The caller of `enforce/4` controls the
  `delete_fun` callback. A common pattern is to export records to cold storage
  before deleting:

```elixir
export_and_delete = fn store, id, _opts ->
  # Export to S3/backup
  record = Tet.Store.get(store, :checkpoint, id)
  Backup.export(:s3, record)

  # Then delete
  Tet.Store.delete(store, :checkpoint, id)
end
```

---

## Audit Record Lifecycle

Here's how audit-critical records flow through the system:

```
Record created
    │
    ▼
Assigned to :audit_critical or :permanent class
    │
    ▼
Stored with created_at timestamp
    │
    ▼
Enforcement runs (daily/weekly)
    │
    ├─ expired_records/3 returns [] (audit-protected records never appear)
    │
    ▼
Record persists indefinitely
    │
    ▼
Manual deletion request
    │
    ├─ check_before_delete → {:error, :audit_protected}
    │
    ├─ acknowledge_delete → {:ok, token}
    │
    ├─ acknowledged_delete → :ok (token verified)
    │
    ▼
Record deleted (only after explicit human acknowledgement)
```

---

## File Reference

| File | Purpose |
|------|---------|
| `apps/tet_core/lib/tet/retention/class.ex` | Retention class definitions and defaults |
| `apps/tet_core/lib/tet/retention/policy.ex` | Policy configuration, data type mapping, ack token generation |
| `apps/tet_core/lib/tet/retention/enforcer.ex` | Pre-deletion checks, expired record discovery, bulk enforcement |
| `apps/tet_core/test/tet/retention/class_test.exs` | Unit tests for retention classes |
| `apps/tet_core/test/tet/retention/policy_test.exs` | Unit tests for policy construction and safety invariants |
| `apps/tet_core/test/tet/retention/enforcer_test.exs` | Unit tests for enforcement logic |

---

## Design Decisions

### Why four classes instead of six?

The initial design spec proposed six classes (`:transient`, `:session`, `:audit`,
`:artifacts`, `:error_log`, `:memory`). The implementation consolidates these
into four because:

1. **`:session` and `:artifacts` map to `:normal`** — 30-day retention with
   configurable max count covers both use cases
2. **`:error_log` maps to `:audit_critical`** — errors are audit evidence,
   not a separate lifecycle
3. **`:memory` maps to `:permanent`** — persistent memory and project lessons
   are human decisions, not auto-prunable

Fewer classes mean fewer configuration surfaces, fewer edge cases, and easier
reasoning about what happens to your data.

### Why HMAC-signed tokens?

Tokens encode the actor, record identity, class, and a random nonce, signed with
HMAC-SHA256. This ensures:
- **Non-forgeable:** Without the secret, tokens can't be created
- **Non-replayable:** Random nonce makes each token unique
- **Non-transferable:** Token is bound to a specific record ID and data type
- **Auditable:** Token contents can be decoded to trace who authorized deletion

### Why per-boot secrets by default?

A per-boot secret means tokens are invalidated on restart. This is intentional:
if someone captures a token, it becomes useless after the process restarts. For
persistence across restarts, configure `ack_secret` explicitly.

---

## Acceptance Criteria

- [x] Document defines all four retention classes with clear TTL rules
- [x] Safety rules prevent silent audit record deletion
- [x] Configuration options are documented (class overrides, data type overrides, ack secret)
- [x] Document stored in `docs/BD-0037_RETENTION_POLICY.md`
- [x] All code paths verified against tests in `apps/tet_core/test/tet/retention/`
