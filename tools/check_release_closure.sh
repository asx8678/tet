#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

if [[ "${1:-}" != "--no-build" ]]; then
  MIX_ENV=prod mix release tet_standalone --overwrite
fi

REL_DIR="$ROOT/_build/prod/rel/tet_standalone"
LIB_DIR="$REL_DIR/lib"

if [[ ! -d "$LIB_DIR" ]]; then
  echo "FAIL: tet_standalone release lib directory not found: $LIB_DIR" >&2
  echo "Run: MIX_ENV=prod mix release tet_standalone --overwrite" >&2
  exit 1
fi

forbidden_name_regex='^(bandit|cowboy|cowlib|phoenix|phoenix_html|phoenix_live|phoenix_live_view|phoenix_pubsub|plug|plug_cowboy|ranch|tet_web|tet_web_phoenix|thousand_island|websock|websock_adapter)([-_].*|$)'

leaked_libs=$(find "$LIB_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -E "$forbidden_name_regex" || true)

if [[ -n "$leaked_libs" ]]; then
  echo "FAIL: forbidden libraries in tet_standalone release closure:" >&2
  echo "$leaked_libs" >&2
  exit 1
fi

metadata_files=$(mktemp)
trap 'rm -f "$metadata_files"' EXIT

find "$REL_DIR/releases" -type f \( -name '*.rel' -o -name 'sys.config' -o -name 'vm.args' \) >> "$metadata_files"
find "$LIB_DIR" -path '*/ebin/*.app' -type f >> "$metadata_files"

metadata_hits=$(xargs grep -n -E '(bandit|cowboy|cowlib|phoenix|phoenix_live_view|phoenix_pubsub|plug|plug_cowboy|ranch|tet_web|tet_web_phoenix|thousand_island|websock|websock_adapter)' < "$metadata_files" || true)

if [[ -n "$metadata_hits" ]]; then
  echo "FAIL: forbidden web framework/app references in release metadata:" >&2
  echo "$metadata_hits" >&2
  exit 1
fi

actual_apps=$(find "$LIB_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sed -E 's/-[^-]+$//' | sort)
required_apps=$'tet_cli\ntet_core\ntet_runtime\ntet_store_sqlite'

missing_required=$(comm -23 <(printf '%s\n' "$required_apps" | sort) <(printf '%s\n' "$actual_apps" | sort) || true)

if [[ -n "$missing_required" ]]; then
  echo "FAIL: tet_standalone release is missing required boundary apps:" >&2
  echo "$missing_required" >&2
  exit 1
fi

echo "OK: tet_standalone release closure contains CLI/runtime/core/store only and no web framework apps"
