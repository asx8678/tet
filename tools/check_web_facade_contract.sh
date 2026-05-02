#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WEB_APP=${TET_WEB_APP_DIR:-"$ROOT/apps/tet_web_phoenix"}

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=1
}

print_hits() {
  local heading=$1
  local hits=$2

  if [[ -n "$hits" ]]; then
    echo "$heading" >&2
    echo "$hits" >&2
  fi
}

collect_app_mix_files() {
  find "$ROOT/apps" \
    -mindepth 2 \
    -maxdepth 2 \
    -type f \
    -name mix.exs \
    ! -path "$WEB_APP/mix.exs" \
    -print0
}

check_non_web_apps_do_not_depend_on_web() {
  local -a mix_files=()
  local hits

  while IFS= read -r -d '' file; do
    mix_files+=("$file")
  done < <(collect_app_mix_files)

  if ((${#mix_files[@]} == 0)); then
    return
  fi

  hits=$(
    grep -nE \
      ':[[:space:]]*(bandit|cowboy|cowlib|phoenix|phoenix_live_dashboard|phoenix_live_view|phoenix_pubsub|plug|plug_cowboy|ranch|tet_web|tet_web_phoenix|thousand_island|websock|websock_adapter)([^[:alnum:]]|$)' \
      "${mix_files[@]}" || true
  )

  if [[ -n "$hits" ]]; then
    print_hits "Non-web umbrella apps must not depend on web frameworks or tet_web apps:" "$hits"
    fail "non-web app dependency contract violated"
  fi
}

check_web_mix_dependencies() {
  local web_mix=$WEB_APP/mix.exs
  local local_hits
  local storage_hits

  if [[ ! -f "$web_mix" ]]; then
    fail "future web app directory exists but mix.exs is missing: $web_mix"
    return
  fi

  local_hits=$(
    grep -nE \
      '\{[[:space:]]*:(tet_cli|tet_store_[[:alnum:]_]+|tet_provider_[[:alnum:]_]+|tet_web_[[:alnum:]_]+)([[:space:],}]|$)' \
      "$web_mix" || true
  )

  if [[ -n "$local_hits" ]]; then
    print_hits "tet_web_phoenix may depend on tet_runtime/tet_core, not CLI/store/provider/web apps:" "$local_hits"
    fail "web adapter has forbidden local umbrella dependencies"
  fi

  storage_hits=$(
    grep -nE \
      ':[[:space:]]*(ecto|ecto_sql|ecto_sqlite3|exqlite|postgrex)([^[:alnum:]_]|$)' \
      "$web_mix" || true
  )

  if [[ -n "$storage_hits" ]]; then
    print_hits "tet_web_phoenix must not own Tet persistence dependencies:" "$storage_hits"
    fail "web adapter has forbidden persistence dependencies"
  fi
}

collect_web_source_files() {
  find "$WEB_APP" \
    -type f \
    \( -name '*.ex' -o -name '*.exs' -o -name '*.heex' \) \
    ! -path '*/_build/*' \
    ! -path '*/deps/*' \
    -print0
}

check_web_source_references() {
  local -a source_files=()
  local forbidden_hits
  local all_tet_refs
  local invalid_tet_refs

  while IFS= read -r -d '' file; do
    source_files+=("$file")
  done < <(collect_web_source_files)

  if ((${#source_files[@]} == 0)); then
    return
  fi

  forbidden_hits=$(
    grep -nE \
      'Tet[.]\{[^}]*(Agent[.]Runtime|Application|CLI|Core|EventBus|Patch|Policy|Prompt|Provider|Runtime|Store|Tool|Tools)[^}]*\}|Tet[.](Agent[.]Runtime|Application|CLI|Core|EventBus|Patch|Policy|Prompt|Provider|Runtime|Store|Tool|Tools)([.[:space:]\{,(]|$)' \
      "${source_files[@]}" || true
  )

  if [[ -n "$forbidden_hits" ]]; then
    print_hits "tet_web_phoenix source must not reference internal Tet modules:" "$forbidden_hits"
    fail "web adapter references forbidden Tet internals"
  fi

  all_tet_refs=$(
    grep -hEo 'Tet[.][A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*' \
      "${source_files[@]}" | sort -u || true
  )

  invalid_tet_refs=$(
    if [[ -n "$all_tet_refs" ]]; then
      echo "$all_tet_refs" | grep -Ev \
        '^Tet[.](Approval|Artifact|Command([.][A-Z][A-Za-z0-9_]*)?|Error|Event|Message|Session|Task|ToolRun|Workspace)$' || true
    fi
  )

  if [[ -n "$invalid_tet_refs" ]]; then
    print_hits "tet_web_phoenix may call root Tet facade functions and render allowed core structs only; unexpected Tet module refs:" "$invalid_tet_refs"
    fail "web adapter has non-facade Tet module references"
  fi
}

check_web_does_not_define_domain_owners() {
  local lib_dir=$WEB_APP/lib
  local owner_dir_hits
  local owner_module_hits
  local -a source_files=()

  if [[ ! -d "$lib_dir" ]]; then
    return
  fi

  owner_dir_hits=$(
    find "$lib_dir" -type d | grep -E \
      '/(agent_runtime|patch|patches|policies|policy|provider|providers|repair|repairs|runtime|store|stores|tool|tools|verification|verifier)(/|$)' || true
  )

  if [[ -n "$owner_dir_hits" ]]; then
    print_hits "tet_web_phoenix must not define domain-owner directories:" "$owner_dir_hits"
    fail "web adapter contains forbidden domain-owner directories"
  fi

  while IFS= read -r -d '' file; do
    source_files+=("$file")
  done < <(collect_web_source_files)

  if ((${#source_files[@]} == 0)); then
    return
  fi

  owner_module_hits=$(
    grep -nE \
      'defmodule[[:space:]]+TetWeb(Phoenix)?([A-Za-z0-9_.]*)[.](AgentRuntime|Patch|Patches|Policies|Policy|Provider|Providers|Repair|Repairs|Runtime|Store|Stores|Tool|Tools|Verification|Verifier)([^[:alnum:]_]|$)' \
      "${source_files[@]}" || true
  )

  if [[ -n "$owner_module_hits" ]]; then
    print_hits "tet_web_phoenix must not define Tet domain-owner modules:" "$owner_module_hits"
    fail "web adapter contains forbidden domain-owner modules"
  fi
}

check_non_web_apps_do_not_depend_on_web

if [[ ! -d "$WEB_APP" ]]; then
  echo "OK: apps/tet_web_phoenix is absent; optional web adapter remains absent"
else
  check_web_mix_dependencies
  check_web_source_references
  check_web_does_not_define_domain_owners
fi

if ((failures != 0)); then
  exit 1
fi

echo "OK: optional tet_web_phoenix facade contract guard passed"
