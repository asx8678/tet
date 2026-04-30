#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_NAME=$(basename "$0")
SKIP_WEB_REMOVABILITY=0
STARTED_AT=$(date +%s)
STEP=0
TOTAL_STEPS=9

usage() {
  cat <<USAGE
Usage: tools/$SCRIPT_NAME [--skip-web-removability]

Runs the deterministic local final release acceptance pipeline for BD-0074.
The local script is the source of truth; future CI should call this script,
not lovingly reimplement it in YAML like a gremlin with a clipboard.

Gates covered:
  1. source/docs/test anchor inventory
  2. mix format --check-formatted
  3. MIX_ENV=test mix compile --warnings-as-errors
  4. full ExUnit suite (unit/invariant-style property/provider/store/recovery/security/web shell)
  5. optional web facade/removability contract guard
  6. standalone release build
  7. standalone dependency-closure/security boundary
  8. offline first-mile release smoke
  9. optional web removability sandbox gate

Options:
  --skip-web-removability  Skip the slow sandbox removability gate. Useful for
                           iteration, but not a final release acceptance run.
  -h, --help               Show this help.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --skip-web-removability)
      SKIP_WEB_REMOVABILITY=1
      TOTAL_STEPS=8
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "FAIL: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

log() {
  echo "==> $*"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

run_step() {
  local description=$1
  shift

  STEP=$((STEP + 1))
  local step_started
  step_started=$(date +%s)

  echo
  log "[$STEP/$TOTAL_STEPS] $description"
  (cd "$ROOT" && "$@")

  local elapsed=$(( $(date +%s) - step_started ))
  log "OK: $description (${elapsed}s)"
}

assert_paths_exist() {
  local label=$1
  shift
  local missing=0

  for path in "$@"; do
    if [[ ! -e "$ROOT/$path" ]]; then
      echo "MISSING [$label]: $path" >&2
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    fail "required $label anchor(s) are missing"
  fi
}

note_optional_source_refs() {
  local refs=(
    "check this plans/plan claude/plan_v0.3/upgrades/17_phasing_and_scope.md"
    "check this plans/plan claude/plan_v0.3/upgrades/18_test_strategy.md"
  )

  for path in "${refs[@]}"; do
    if [[ ! -e "$ROOT/$path" ]]; then
      log "NOTE: optional source ref unavailable in this worktree: $path"
    fi
  done
}

check_source_and_test_anchors() {
  assert_paths_exist "phase/source" \
    "mix.exs" \
    "plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md" \
    "docs/research/BD-0003_PHASE_BACKLOG_TRACEABILITY_MATRIX.md" \
    "docs/adr/0001-standalone-cli-boundary.md" \
    "docs/adr/0002-phoenix-optional-adapter.md" \
    "docs/adr/0005-gates-approvals-verification.md" \
    "docs/adr/0006-storage-names-and-boundaries.md" \
    "docs/adr/0008-repair-and-error-recovery.md" \
    "docs/BD-0074_FINAL_RELEASE_ACCEPTANCE_PIPELINE.md"

  assert_paths_exist "release tooling" \
    "tools/check_release_acceptance.sh" \
    "tools/smoke_first_mile.sh" \
    "tools/check_release_closure.sh" \
    "tools/check_web_facade_contract.sh" \
    "tools/check_web_removability.sh" \
    "rel/overlays/bin/tet"

  assert_paths_exist "test coverage" \
    "apps/tet_core/test/tet/tool_contract_test.exs" \
    "apps/tet_core/test/tet/compaction_test.exs" \
    "apps/tet_core/test/tet/prompt_test.exs" \
    "apps/tet_runtime/test/tet/provider_router_test.exs" \
    "apps/tet_runtime/test/tet/provider_streaming_test.exs" \
    "apps/tet_runtime/test/tet/autosave_restore_test.exs" \
    "apps/tet_runtime/test/tet/remote_worker_bootstrap_test.exs" \
    "apps/tet_runtime/test/tet/standalone_boundary_test.exs" \
    "apps/tet_store_sqlite/test/prompt_history_test.exs" \
    "apps/tet_cli/test/tet_cli_test.exs" \
    "apps/tet_web_phoenix/test/tet_web_phoenix/dashboard_test.exs"

  note_optional_source_refs
}

run_web_facade_contract() {
  "$ROOT/tools/check_web_facade_contract.sh"
}

build_standalone_release() {
  MIX_ENV=prod mix release tet_standalone --overwrite
}

run_release_closure_no_build() {
  "$ROOT/tools/check_release_closure.sh" --no-build
}

run_first_mile_smoke_no_build() {
  "$ROOT/tools/smoke_first_mile.sh" --no-build
}

run_web_removability() {
  "$ROOT/tools/check_web_removability.sh"
}

main() {
  require_command mix
  require_command grep
  require_command mktemp

  if [[ "$SKIP_WEB_REMOVABILITY" == "1" ]]; then
    log "WARNING: skipping web removability sandbox gate; this is not final-release complete"
  fi

  run_step "check source, documentation, release-tool, and coverage anchors" \
    check_source_and_test_anchors
  run_step "check formatting" mix format --check-formatted
  run_step "compile with warnings as errors" env MIX_ENV=test mix compile --warnings-as-errors
  run_step "run full ExUnit suite" env MIX_ENV=test mix test
  run_step "run optional web facade boundary guard" run_web_facade_contract
  run_step "build tet_standalone release" build_standalone_release
  run_step "check standalone release closure/security boundary" run_release_closure_no_build
  run_step "run offline first-mile release smoke" run_first_mile_smoke_no_build

  if [[ "$SKIP_WEB_REMOVABILITY" == "0" ]]; then
    run_step "run optional web removability sandbox gate" run_web_removability
  fi

  local elapsed=$(( $(date +%s) - STARTED_AT ))
  echo
  if [[ "$SKIP_WEB_REMOVABILITY" == "1" ]]; then
    log "OK: BD-0074 partial/iteration acceptance passed; web removability was skipped and this is not release-complete (${elapsed}s total)"
  else
    log "OK: BD-0074 final release acceptance pipeline passed (${elapsed}s total)"
  fi
}

main
