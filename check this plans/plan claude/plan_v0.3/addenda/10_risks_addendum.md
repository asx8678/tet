# 10 — Risks Addendum

> Updates `docs/10_risks_mitigations.md`. The original plan listed 12
> numbered risks (R1–R12). v0.3's additions changed the picture: some
> risks are now solved or downgraded, some take a new shape, and new
> risks emerge from the durable execution layer and the redaction
> layers. This doc reconciles the register.

## Status of original risks R1–R12

| ID  | Original risk                                         | v0.3 status     | Notes |
| --- | ----------------------------------------------------- | --------------- | ----- |
| R1  | Phoenix code paths leak into core/runtime             | unchanged       | Five gates + facade-only guard remain the defense; release-closure check is unchanged. |
| R2  | Tool runs corrupt the workspace                       | **downgraded**  | Atomic patch with per-change-type rollback (doc 12) plus crash recovery makes torn workspaces recoverable rather than a permanent bad state. |
| R3  | Path traversal escapes workspace root                 | **downgraded**  | Property and fuzz tests (doc 18 L2) cover 10_000 random paths, not just curated examples. Reason atom registry from corrections §4 is exhaustive. |
| R4  | Secrets visible in logs / events / display            | **changed**     | Original mitigation was display-layer redaction only. v0.3 adds inbound (file→prompt) and outbound (logs/audit) layers (doc 14). The risk is reduced but not eliminated; explicitly best-effort. |
| R5  | Approval state machine bugs allow unsafe writes       | **downgraded**  | Property tests for state-machine reachability (doc 18 L2). Workflow journal makes the state inspectable post-hoc. |
| R6  | SQLite single-writer causes contention or corruption  | unchanged       | WAL mode, single per-workspace BEAM, no multi-process writers. |
| R7  | User intent drift across long sessions                | **partially solved** | Workflow journal provides a complete reconstructable history; `tet truncate` gives explicit user control. Remaining drift is product-level (model misunderstands instructions), not infrastructure. |
| R8  | Provider API surface drift                            | **changed**     | Contract from doc 11 plus conformance tests (doc 18 L3) detect drift before deployment. New sub-risk: bidirectional tool-call map breaks on provider-format changes. |
| R9  | Verifier shells out to attacker-controlled commands   | unchanged       | Allowlist-only verifier names, no shell strings. v0.3 tightens env scrubbing (doc 14). |
| R10 | Verifier becomes generic shell exec                   | **reinforced**  | Doc 14 env scrubbing definition makes the boundary harder to drift across. |
| R11 | Schema migration corrupts existing workspaces         | **changed**     | `tet doctor` schema-version check + `tet migrate` + workflow journal as separate, non-disruptive table (doc 19). Forward-only migrations with restore-from-backup as the rollback. |
| R12 | Removability test rots over time                      | unchanged       | Still in CI; v0.3 adds the audit guards but the removability test itself is the same. |

## New risks introduced by v0.3

### R13 — Workflow journal corruption

**Risk.** A bug in the executor or store adapter writes inconsistent
journal state (e.g., `start_step` succeeds but `commit_step` is never
called, or step output is mis-encoded). Recovery on restart misreads
the state and either re-runs a committed side effect or skips an
uncommitted one.

**Likelihood.** Low. **Impact.** High (workspace corruption, double
billing on provider calls, or silent data loss).

**Mitigations.**

- L4 store contract tests (doc 18) — the same suite runs against
  memory, SQLite, and (post-v1) Postgres adapters; behavioral parity
  is enforced.
- L5 crash-recovery integration tests run nightly with SIGKILL at
  every step boundary documented in doc 12.
- Unique constraint on `(workflow_id, idempotency_key)` enforces
  exactly-once commit at the storage level — bypasses requires
  bypassing the store adapter.
- Property test on replay determinism catches order-sensitive bugs.
- The journal is append-only at the application level; no UPDATE on
  committed step rows. Inspection commands are read-only.

### R14 — Recovery double-execution

**Risk.** A step that performed a side effect commits *almost* — the
side effect lands but the commit doesn't reach storage before the
crash. Restart sees the step as `:started`, replays it, side effect
runs twice.

**Likelihood.** Real and inherent to durable execution.

**Mitigations.**

- Idempotency keys on every step. Provider calls with the same
  `request_id` are recognized by the journal-cached response.
- Tool runs for read tools are (almost always) idempotent — the
  category is preferred for any dangerous tool.
- Patch apply is the only side effect that materially changes the
  workspace; its recovery decision tree (doc 12) is conservative
  (rollback unconditionally on snapshot-present-but-status-started),
  trading one false-positive rollback for safety.
- `emit_event` doubling is explicitly allowed; subscribers dedupe
  by `event.id`.
- For tool runs whose inputs aren't naturally idempotent (e.g., a
  hypothetical `send_email` tool), the tool author must declare it
  with `idempotent: false` and the runtime requires the user to
  explicitly mark `--allow-side-effect-on-recovery` to resume the
  workflow. v1 ships no such tools.

### R15 — Redaction bypass

**Risk.** A secret matches no layer-1 pattern, falls below the
entropy threshold, lives in a path not covered by deny-globs, and
streams to the provider in plaintext.

**Likelihood.** Real for custom internal credential formats.

**Mitigations.**

- Honest framing in doc 14: layered redaction is best-effort.
- Deny-glob defense in depth (corrections §4): keep agent away from
  `priv/secrets/`, `.env`, `~/.aws/`, etc., as the primary defense.
- Configurable entropy threshold; users can tighten in
  high-sensitivity workspaces.
- Audit log records every redaction event for after-the-fact review.
- Recommendation in docs: use a local provider (llama.cpp, Ollama,
  vLLM) when handling sensitive code.
- L2 property test (doc 18) with planted secrets across a random
  file corpus measures real-world catch rate over time.

### R16 — MCP server misclassifies its tools

**Risk.** A third-party MCP server declares a write-affecting tool
as `readOnlyHint: true`. If trusted, it would bypass approval policy.

**Likelihood.** Real once the MCP ecosystem grows (v1.x concern).

**Mitigations.**

- All MCP tools default to `:write` regardless of server self-report
  (extensions §"Read-only classification").
- Operator allowlist is the only path to `:read` classification.
- `tet mcp tools <name>` shows the server's `readOnlyHint` for human
  review without applying it.
- This is a v1.x risk because MCP is v1.x; the design defends the
  default before the feature ships.

### R17 — Patch validator over-rejection on redacted regions

**Risk.** A patch that legitimately needs to touch a redacted region
(e.g., user is asking the agent to rotate an API key) is rejected by
`Tet.Patch.validate/2`, frustrating users.

**Likelihood.** Real but bounded — secret rotation is a specific
workflow.

**Mitigations.**

- Error message is explicit (`:patch_touches_redacted_region`) and
  names the file plus line range.
- Documented escape hatches: rotate the key out-of-band first; or
  `tet truncate` to drop the file-read from history; or use
  `--allow-redacted-edit` on the approval (post-v1; not in initial
  cut to encourage the safer paths).
- This is a usability risk, not a safety one. Defaulting to safe is
  correct.

### R18 — Stale completion cache surfaces wrong values

**Risk.** Shell completion offers a session id that no longer exists
or omits a session that was just created, and the user spends time
debugging why their command "doesn't work."

**Likelihood.** Low; worst case is a brief cosmetic mismatch.

**Mitigations.**

- Cache is refreshed on every relevant runtime event (session new,
  approval change, etc.).
- Stale cache (>24h) is silently dropped; static completion still
  works.
- Cache schema is versioned in its first key; on schema mismatch the
  completion script falls through.

### R19 — Multi-node split-brain (v1.x)

**Risk.** Two `tet_web` nodes both believe they own a workflow and
both run the executor — duplicate side effects.

**Likelihood.** Real in any multi-node design with naïve coordination
(v0.2's 30s polling had this property).

**Mitigations.**

- v0.3 design uses Postgres advisory locks for ownership claim, which
  are released on connection death (doc 13). No polling; no race.
- Single-node deployments are unaffected.
- This risk applies only to v1.x multi-node `tet_web`; v1 acceptance
  does not require multi-node correctness.

### R20 — Boundary-guard rot on v0.3 additions

**Risk.** New code paths added in v0.3 (atom-encoding guards,
credential-env guards, the no-`SessionWorker` source guard) drift out
of CI over time, allowing forbidden patterns back in.

**Likelihood.** Low if the guards are written; high if they aren't.

**Mitigations.**

- Each guard ships with a deliberate failing fixture committed under
  `tools/test_guards_fail/` so the guard's CI step fails if the
  guard itself is removed.
- Guards run on every push (L6 in doc 18), not nightly.

## Risk priority for v1 launch readiness

In rough order of "what would I worry about most before shipping":

1. **R14 (recovery double-execution)** — pervasive; gates v1.
2. **R13 (journal corruption)** — pervasive; gates v1.
3. **R2 / R7 (workspace corruption / approval state)** — both
   downgraded, but the rollback rewrite is significant new code.
4. **R15 (redaction bypass)** — bounded by best-effort framing;
   continuous improvement.
5. **R3 (path traversal)** — well-tested but security-critical.
6. **R8 (provider drift)** — real but quickly detected by
   conformance suite.
7. R20, R18, R17 — operational rather than safety risks.

R16, R19 are v1.x and deferred.

## Acceptance for this register

- [ ] Every original R1–R12 has a v0.3 status here.
- [ ] Every new v0.3 risk has at least one named mitigation that maps
      to a concrete acceptance item in another doc or checklist.
- [ ] R13 and R14 mitigations are present in the v1 acceptance
      checklist (`checklists/final_acceptance_checklist_v0.3.md`).
- [ ] R20's failing-fixture guards are present under `tools/`.
