# 10 — Risks and Mitigations

## R1. Phoenix sneaks back into core/runtime

Mitigation: five gates, source guard, xref guard, release closure check, and removability test.

## R2. Business logic ends up in LiveView

Mitigation: facade-only UI rule, small LiveView modules, code review checklist, cross-UI consistency tests.

## R3. Public facade grows too broad

Mitigation: expose task-oriented functions, not internals; document compatibility; review facade additions as API changes.

## R4. `tet_core` accidentally depends on runtime

Mitigation: keep `Tet` facade in `tet_runtime`; `tet_core` defines structs/behaviours only; xref catches `Tet.Runtime` references in core.

## R5. Storage abstraction becomes fake

Mitigation: shared contract tests for memory/sqlite/postgres; no direct store calls from CLI/Phoenix; no Ecto schemas in core.

## R6. CLI and web drift apart

Mitigation: both call `Tet.*`; both render `%Tet.Event{}`; tests compare event sequences for equivalent actions.

## R7. Approval semantics drift

Mitigation: approval state helpers in core; patch application is a separate tool-run result; CLI/Phoenix cannot set file state directly.

## R8. Standalone release accidentally pulls Phoenix transitively

Mitigation: release closure gate scans built release libs, not just source deps.

## R9. Path traversal leaks files outside workspace

Mitigation: canonical path resolver, symlink tests, adversarial path test list, `.tet/` hidden by default.

## R10. Verifier becomes arbitrary shell execution

Mitigation: named allowlist only; no raw shell strings; scrubbed env; timeout; stdout/stderr artifacts; redaction.

## R11. Provider/tool failure crashes the CLI

Mitigation: runtime converts failures into structured events/errors; CLI renders deterministic exit codes.

## R12. Tests pass but release fails

Mitigation: release closure check and milestone script run against built release, not only Mix test.
