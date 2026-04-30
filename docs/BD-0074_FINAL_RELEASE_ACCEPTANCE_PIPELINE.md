# BD-0074 Final release acceptance pipeline

Issue: `tet-db6.74` / `BD-0074: Final release acceptance pipeline`
Category: verifying
Phase: 20 / Packaging, documentation, migration, and release

This document defines the local release-acceptance gate for Tet's current
standalone CLI + optional web-adapter architecture. The source of truth is the
local shell script:

```sh
tools/check_release_acceptance.sh
```

The Mix alias is a convenience wrapper around the same script:

```sh
mix release.acceptance
```

Future CI should call the script instead of duplicating the gate list in a
workflow file. YAML that drifts from local release reality is just confetti with
indentation.

## Source anchors

Primary anchors available in this isolated worktree:

- `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`, especially Phase 20.
- `docs/research/BD-0003_PHASE_BACKLOG_TRACEABILITY_MATRIX.md`, especially
  Phase 20 and its BD-0074 row.
- `docs/adr/0001-standalone-cli-boundary.md` for the standalone release spine.
- `docs/adr/0002-phoenix-optional-adapter.md` for web removability.
- `docs/adr/0005-gates-approvals-verification.md` for release gates.
- `docs/adr/0006-storage-names-and-boundaries.md` for `.tet/` storage names.
- `docs/adr/0008-repair-and-error-recovery.md` for recovery/rollback framing.
- Existing release guards in `tools/check_release_closure.sh`,
  `tools/check_web_facade_contract.sh`, and
  `tools/check_web_removability.sh`.

The issue also references:

- `check this plans/plan claude/plan_v0.3/upgrades/17_phasing_and_scope.md`
- `check this plans/plan claude/plan_v0.3/upgrades/18_test_strategy.md`

Those exact expanded `plan_v0.3/upgrades/*` files are not present in this
isolated worktree. The acceptance script notes them as unavailable source refs
rather than failing; this keeps the gate deterministic for reviewers working
from `main` while preserving the citation trail if those files are restored or
unpacked later.

## Commands

Full final-release acceptance:

```sh
mix release.acceptance
# equivalent to:
tools/check_release_acceptance.sh
```

Fast iteration when the sandbox removability copy is too expensive:

```sh
tools/check_release_acceptance.sh --skip-web-removability
```

Do **not** treat `--skip-web-removability` as final-release complete. It exists
for development loops only. Final acceptance includes the sandbox removability
gate because optional Phoenix is not allowed to quietly glue itself to the CLI
like a needy barnacle.

Standalone first-mile smoke only:

```sh
mix smoke.first_mile
# equivalent to:
tools/smoke_first_mile.sh
```

If the release has already been assembled:

```sh
tools/smoke_first_mile.sh --no-build
```

## Gate map

Property coverage note: BD-0074 names property coverage as a release surface. The current repo does not ship a dedicated property-test dependency/framework, so the gate maps that requirement to existing deterministic invariant-style ExUnit coverage and documents this as the current evidence rather than pretending a separate property suite exists.

| Gate | Command/source | Proves |
| --- | --- | --- |
| Source/docs/test anchor inventory | Built into `tools/check_release_acceptance.sh` | Required local source anchors, release scripts, docs, and representative test files exist before the expensive gates run. Missing source refs from the issue are reported explicitly. |
| Formatting | `mix format --check-formatted` | Code and Mix files match the repo formatter. Tiny gate, big shame if skipped. |
| Compile warnings | `MIX_ENV=test mix compile --warnings-as-errors` | The umbrella compiles cleanly and warning-free in the test profile. |
| Full ExUnit suite | `MIX_ENV=test mix test` | Runs all current unit and invariant-style property coverage across core, runtime, CLI, store, and optional web shell. This repo does not currently use a dedicated property-test framework such as StreamData; property coverage is represented by existing deterministic invariants until a future property suite exists. This is where provider, store, recovery, remote bootstrap, boundary, and rendering regressions should scream. |
| Provider path | Full ExUnit suite, anchored by `apps/tet_runtime/test/tet/provider_router_test.exs` and `apps/tet_runtime/test/tet/provider_streaming_test.exs` | Mock/router/provider streaming behavior works without network or real provider credentials. |
| Store path | Full ExUnit suite, anchored by `apps/tet_store_sqlite/test/prompt_history_test.exs` and runtime store/autosave tests | `.tet/` JSONL-backed store adapter can persist/read sessions, events, autosaves, and Prompt Lab history through runtime-owned boundaries. |
| Recovery/autosave/remote bootstrap | Full ExUnit suite, anchored by `apps/tet_runtime/test/tet/autosave_restore_test.exs` and `apps/tet_runtime/test/tet/remote_worker_bootstrap_test.exs` | Recovery and remote bootstrap protocols are fakeable/local and do not require SSH or real remote hosts. |
| Security/boundary checks | `tools/check_web_facade_contract.sh`, `tools/check_release_closure.sh --no-build`, and boundary tests | Web dependencies stay out of non-web apps and the `tet_standalone` release closure; optional web calls only allowed facade surfaces; provider secrets are diagnosed without leaking raw credentials. |
| Standalone release build | `MIX_ENV=prod mix release tet_standalone --overwrite` | Assembles the product artifact reviewers actually smoke, instead of just admiring green unit tests from a distance. |
| First-mile system smoke | `tools/smoke_first_mile.sh --no-build` | Runs the assembled release wrapper offline with `TET_PROVIDER=mock` and sandboxed store paths through `help`, `doctor`, `profiles`, `ask`, `sessions`, `session show`, and `events`. |
| Web removability | `tools/check_web_removability.sh` | Copies the repo to a disposable sandbox, removes optional web apps, compiles/tests/builds standalone, and proves the facade guard catches a synthetic Phoenix leak. |

## First-mile smoke behavior

`tools/smoke_first_mile.sh` is intentionally offline and deterministic:

- Builds `tet_standalone` unless `--no-build` is supplied.
- Runs only the release wrapper at `_build/prod/rel/tet_standalone/bin/tet`.
- Uses a temporary workspace, not the repo root, for runtime execution.
- Runs the release wrapper under a sanitized `env -i` environment so inherited
  caller `TET_*` registry/profile/provider variables cannot contaminate or mask
  the artifact smoke. Only a minimal OS allowlist plus the smoke-specific Tet
  variables below are passed through.
- Sets:
  - `TET_PROVIDER=mock`
  - `TET_STORE_PATH=<temp>/.tet/messages.jsonl`
  - `TET_EVENTS_PATH=<temp>/.tet/events.jsonl`
  - `TET_AUTOSAVE_PATH=<temp>/.tet/autosaves.jsonl`
  - `TET_PROMPT_HISTORY_PATH=<temp>/.tet/prompt_history.jsonl`
- Forces bundled registry/profile defaults by clearing `TET_MODEL_REGISTRY_PATH`,
  `TET_PROFILE_REGISTRY_PATH`, and `TET_PROFILE` inside the sanitized
  environment.
- Requires no network, no SSH, no API keys, and no provider accounts.
- Verifies persisted messages and events are non-empty after `tet ask`.

This gives reviewers a cheap answer to: "If I unpack the release and run the
first commands a user would run, does it work?" Revolutionary stuff, apparently.

## Relationship to Phase 20 acceptance

Phase 20 says final release acceptance must prove:

- standalone package installs/runs without Phoenix;
- optional web package remains separate/removable;
- docs cover release and recovery paths;
- release build, closure, smoke, acceptance pipeline, and rollback/recovery
  evidence exist;
- migration remains safe/dry-run-first where implemented.

Current repo state does not yet contain a full migration command/package matrix,
so BD-0074 does not invent one. This pipeline proves the release mechanics that
exist today and leaves migration-specific fixture gates to the future migration
implementation. YAGNI is still a rule, not a decorative wall sticker.

## CI integration guidance

No `.github` workflow is required for this issue. If CI is added later, keep the
local script as the only source of truth:

```yaml
- run: tools/check_release_acceptance.sh
```

A slower scheduled job may run the full default pipeline. Pull-request jobs may
choose `--skip-web-removability` only if another required job runs the full gate
before release.

## Caveats and out-of-scope items

- No real providers are contacted. Provider acceptance uses mock/router tests
  and the first-mile smoke forces `TET_PROVIDER=mock`.
- No remote hosts are contacted. Remote bootstrap acceptance uses fakeable
  transports in ExUnit.
- No secrets are required or written. Provider diagnostics assert missing-secret
  behavior without raw credentials.
- No package upload, GitHub release, PR creation, or push is performed.
- The exact expanded `plan_v0.3/upgrades/17` and `18` source refs are absent in
  this worktree and are noted as unavailable by the script.
