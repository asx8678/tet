#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_NAME=$(basename "$0")

KEEP_SANDBOX=${TET_REMOVABILITY_KEEP_SANDBOX:-0}
SKIP_NEGATIVE_SMOKE=0

usage() {
  cat <<USAGE
Usage: tools/$SCRIPT_NAME [--skip-negative-smoke]

Proves the standalone Tet path is removable from the optional web adapter by:
  1. running the web facade/source dependency guard in this working tree;
  2. injecting a temporary non-web Phoenix dependency and proving the guard fails;
  3. copying this working tree to a disposable sandbox without .git/.beads/builds;
  4. deleting apps/tet_web and apps/tet_web_* from the sandbox;
  5. running compile --warnings-as-errors and mix standalone.check in the sandbox.

Set TET_REMOVABILITY_KEEP_SANDBOX=1 to keep the sandbox for debugging.
USAGE
}

while (($# > 0)); do
  case "$1" in
    --skip-negative-smoke)
      SKIP_NEGATIVE_SMOKE=1
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

make_temp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/tet-web-removability.XXXXXX"
}

copy_repo_to() {
  local destination=$1

  rsync -a --delete \
    --exclude '.git/' \
    --exclude '.beads/' \
    --exclude '_build/' \
    --exclude 'deps/' \
    --exclude '.elixir_ls/' \
    --exclude 'cover/' \
    --exclude 'erl_crash.dump' \
    --exclude '.DS_Store' \
    "$ROOT/" "$destination/"
}

remove_optional_web_apps() {
  local workspace=$1
  local apps_dir=$workspace/apps
  local removed_file=$workspace/.tet-web-removability-removed-apps

  : > "$removed_file"

  if [[ ! -d "$apps_dir" ]]; then
    fail "apps directory missing from sandbox: $apps_dir"
  fi

  while IFS= read -r -d '' app_dir; do
    basename "$app_dir" >> "$removed_file"
    rm -rf "$app_dir"
  done < <(
    find "$apps_dir" \
      -mindepth 1 \
      -maxdepth 1 \
      -type d \
      \( -name 'tet_web' -o -name 'tet_web_*' \) \
      -print0
  )

  if [[ -s "$removed_file" ]]; then
    log "removed optional web app(s): $(paste -sd ', ' "$removed_file")"
  else
    log "no optional web app directories found; proving standalone path without one present"
  fi
}

run_in() {
  local workspace=$1
  shift

  log "(sandbox) $*"
  (cd "$workspace" && "$@")
}

run_negative_smoke() {
  local tmp_root sandbox output status

  tmp_root=$(make_temp_dir)
  sandbox=$tmp_root/repo
  mkdir -p "$sandbox"

  copy_repo_to "$sandbox"
  mkdir -p "$sandbox/apps/tet_negative_web_leak"

  cat > "$sandbox/apps/tet_negative_web_leak/mix.exs" <<'FIXTURE'
defmodule TetNegativeWebLeak.MixProject do
  use Mix.Project

  def project do
    [
      app: :tet_negative_web_leak,
      version: "0.1.0",
      deps: [
        {:phoenix, "~> 1.7"}
      ]
    ]
  end
end
FIXTURE

  set +e
  output=$(cd "$sandbox" && tools/check_web_facade_contract.sh 2>&1)
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "$output" >&2
    fail "negative smoke did not catch a non-web Phoenix dependency leak"
  fi

  if ! grep -Eq 'non-web app dependency contract violated|Non-web umbrella apps must not depend' <<< "$output"; then
    echo "$output" >&2
    fail "negative smoke failed for an unexpected reason"
  fi

  log "negative smoke passed: non-web Phoenix dependency leak was rejected"

  if [[ "$KEEP_SANDBOX" == "1" ]]; then
    log "kept negative-smoke sandbox: $sandbox"
  else
    rm -rf "$tmp_root"
  fi
}

run_positive_gate() {
  local tmp_root sandbox

  tmp_root=$(make_temp_dir)
  sandbox=$tmp_root/repo
  mkdir -p "$sandbox"

  copy_repo_to "$sandbox"
  remove_optional_web_apps "$sandbox"

  run_in "$sandbox" env MIX_ENV=test mix compile --warnings-as-errors
  run_in "$sandbox" env MIX_ENV=test mix standalone.check

  local release_lib=$sandbox/_build/prod/rel/tet_standalone/lib

  if [[ ! -d "$release_lib" ]]; then
    fail "sandbox tet_standalone release lib directory was not built: $release_lib"
  fi

  if find "$release_lib" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -Eq '^(bandit|cowboy|cowlib|phoenix|phoenix_html|phoenix_live|phoenix_live_view|phoenix_pubsub|plug|plug_cowboy|ranch|tet_web|tet_web_phoenix|thousand_island|websock|websock_adapter)([-_].*|$)'; then
    fail "forbidden web library found in sandbox tet_standalone release"
  fi

  if [[ "$KEEP_SANDBOX" == "1" ]]; then
    log "kept removability sandbox: $sandbox"
  else
    rm -rf "$tmp_root"
  fi
}

main() {
  require_command rsync
  require_command mix

  log "checking web facade/non-web dependency contract in working tree"
  "$ROOT/tools/check_web_facade_contract.sh"

  if [[ "$SKIP_NEGATIVE_SMOKE" == "0" ]]; then
    run_negative_smoke
  else
    log "negative smoke skipped"
  fi

  run_positive_gate

  log "OK: standalone compile/test/release pass after removing optional web app directories"
}

main
