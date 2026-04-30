#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_NAME=$(basename "$0")
REL_DIR="$ROOT/_build/prod/rel/tet_standalone"
TET_BIN="$REL_DIR/bin/tet"
BUILD_RELEASE=1
KEEP_WORKSPACE=${TET_FIRST_MILE_KEEP_WORKSPACE:-0}
WORKSPACE=""

usage() {
  cat <<USAGE
Usage: tools/$SCRIPT_NAME [--no-build] [--keep-workspace]

Runs an offline first-mile smoke against the assembled tet_standalone release:
  1. builds the release unless --no-build is supplied;
  2. verifies the release wrapper exists and is executable;
  3. runs tet help, doctor, profiles, ask, sessions, session show, and events;
  4. runs under a sanitized env with TET_PROVIDER=mock and sandboxed .tet paths,
     so caller TET_* config, network, secrets, and SSH cannot affect the smoke.

This is intentionally boring. Boring smoke tests ship releases; dramatic ones ship excuses.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --no-build)
      BUILD_RELEASE=0
      shift
      ;;
    --keep-workspace)
      KEEP_WORKSPACE=1
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

cleanup() {
  if [[ -n "$WORKSPACE" && -d "$WORKSPACE" ]]; then
    if [[ "$KEEP_WORKSPACE" == "1" ]]; then
      log "kept first-mile smoke workspace: $WORKSPACE"
    else
      rm -rf "$WORKSPACE"
    fi
  fi
}

trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

make_temp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/tet-first-mile.XXXXXX"
}

assert_contains() {
  local file=$1
  local expected=$2

  if ! grep -Fq "$expected" "$file"; then
    echo "--- $file ---" >&2
    cat "$file" >&2
    echo "--- end $file ---" >&2
    fail "expected output to contain: $expected"
  fi
}

assert_file_nonempty() {
  local file=$1

  if [[ ! -s "$file" ]]; then
    fail "expected non-empty file: $file"
  fi
}

run_tet() {
  local name=$1
  shift

  local outfile="$WORKSPACE/out/$name.out"
  log "tet $*" >&2

  set +e
  (
    cd "$WORKSPACE/run"
    env -i \
      PATH="${PATH:-/usr/bin:/bin}" \
      HOME="$WORKSPACE/home" \
      TMPDIR="$WORKSPACE/tmp" \
      LANG="${LANG:-C}" \
      LC_ALL="${LC_ALL:-C}" \
      TET_PROVIDER=mock \
      TET_STORE_PATH="$WORKSPACE/.tet/messages.jsonl" \
      TET_EVENTS_PATH="$WORKSPACE/.tet/events.jsonl" \
      TET_AUTOSAVE_PATH="$WORKSPACE/.tet/autosaves.jsonl" \
      TET_PROMPT_HISTORY_PATH="$WORKSPACE/.tet/prompt_history.jsonl" \
      TET_MODEL_REGISTRY_PATH= \
      TET_PROFILE_REGISTRY_PATH= \
      TET_PROFILE= \
      "$TET_BIN" "$@"
  ) > "$outfile" 2>&1
  local status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    echo "--- tet $* output ---" >&2
    cat "$outfile" >&2
    echo "--- end output ---" >&2
    fail "tet $* exited with status $status"
  fi

  echo "$outfile"
}

build_release() {
  if [[ "$BUILD_RELEASE" == "1" ]]; then
    require_command mix
    log "building tet_standalone release"
    (cd "$ROOT" && MIX_ENV=prod mix release tet_standalone --overwrite)
  else
    log "using existing tet_standalone release (--no-build)"
  fi
}

assert_release_wrapper() {
  if [[ ! -x "$TET_BIN" ]]; then
    fail "tet release wrapper is missing or not executable: $TET_BIN"
  fi

  if [[ ! -x "$REL_DIR/bin/tet_standalone" ]]; then
    fail "tet_standalone release executable is missing: $REL_DIR/bin/tet_standalone"
  fi
}

main() {
  require_command grep
  require_command mktemp

  build_release
  assert_release_wrapper

  WORKSPACE=$(make_temp_dir)
  mkdir -p "$WORKSPACE/out" "$WORKSPACE/run" "$WORKSPACE/.tet" "$WORKSPACE/home" "$WORKSPACE/tmp"

  local help_out doctor_out profiles_out ask_out sessions_out session_out events_out

  help_out=$(run_tet help help)
  assert_contains "$help_out" "tet - standalone Tet CLI scaffold"
  assert_contains "$help_out" "tet doctor"

  doctor_out=$(run_tet doctor doctor)
  assert_contains "$doctor_out" "Tet standalone doctor: ok"
  assert_contains "$doctor_out" "provider: :mock (ok)"
  assert_contains "$doctor_out" "release_boundary: ok"

  profiles_out=$(run_tet profiles profiles)
  assert_contains "$profiles_out" "Profiles:"

  ask_out=$(run_tet ask ask --session first-mile "hello release")
  assert_contains "$ask_out" "mock: hello release"

  sessions_out=$(run_tet sessions sessions)
  assert_contains "$sessions_out" "Sessions:"
  assert_contains "$sessions_out" "first-mile"

  session_out=$(run_tet session_show session show first-mile)
  assert_contains "$session_out" "Session first-mile"
  assert_contains "$session_out" "hello release"
  assert_contains "$session_out" "mock: hello release"

  events_out=$(run_tet events events --session first-mile)
  assert_contains "$events_out" "Events:"
  assert_contains "$events_out" "provider_text_delta"
  assert_contains "$events_out" "message_persisted"

  assert_file_nonempty "$WORKSPACE/.tet/messages.jsonl"
  assert_file_nonempty "$WORKSPACE/.tet/events.jsonl"

  log "OK: first-mile release smoke passed offline with mock provider and sandboxed store"
}

main
