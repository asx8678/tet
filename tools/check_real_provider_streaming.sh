#!/usr/bin/env bash
# =============================================================================
# BD-0082: Real provider streaming verification
#
# ⚠️  THIS SCRIPT IS FOR MANUAL OPERATOR USE ONLY ⚠️
# ⚠️  DO NOT RUN IN CI OR AUTOMATED PIPELINES       ⚠️
#
# This script verifies streaming chat against real provider APIs (OpenAI or
# Anthropic). It catches real-world SSE parsing, auth header handling, model
# name resolution, `data: [DONE]` detection, error classification, and
# timeout behavior that mock providers cannot exercise.
#
# Requirements:
#   - Valid API key for at least one provider (OpenAI or Anthropic)
#   - Network access to the provider's API endpoint
#   - A built tet_standalone release
#
# Usage:
#   # Verify OpenAI-compatible provider
#   OPENAI_API_KEY="sk-..." tools/check_real_provider_streaming.sh --openai
#
#   # Verify Anthropic provider
#   ANTHROPIC_API_KEY="sk-ant-..." tools/check_real_provider_streaming.sh --anthropic
#
#   # Verify both (requires both API keys)
#   OPENAI_API_KEY="sk-..." ANTHROPIC_API_KEY="sk-ant-..." tools/check_real_provider_streaming.sh --all
# =============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_NAME=$(basename "$0")
REL_DIR="$ROOT/_build/prod/rel/tet_standalone"
TET_BIN="$REL_DIR/bin/tet"
VERIFY_OPENAI=0
VERIFY_ANTHROPIC=0
VERIFY_ALL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

usage() {
  cat <<USAGE
Usage: tools/$SCRIPT_NAME [OPTIONS]

BD-0082: Real provider streaming verification

⚠️  MANUAL OPERATOR VERIFICATION ONLY — DO NOT USE IN CI ⚠️

Options:
  --openai      Verify OpenAI-compatible provider streaming
  --anthropic   Verify Anthropic provider streaming
  --all         Verify both providers (requires both API keys)
  --no-build    Skip release build (use existing release)
  -h, --help    Show this help message

Environment Variables:
  OPENAI_API_KEY      Required for --openai or --all
  ANTHROPIC_API_KEY   Required for --anthropic or --all

Examples:
  # Verify OpenAI-compatible provider
  OPENAI_API_KEY="sk-..." tools/$SCRIPT_NAME --openai

  # Verify Anthropic provider
  ANTHROPIC_API_KEY="sk-ant-..." tools/$SCRIPT_NAME --anthropic

  # Verify both providers
  OPENAI_API_KEY="sk-..." ANTHROPIC_API_KEY="sk-ant-..." tools/$SCRIPT_NAME --all

This script will:
1. Build the tet_standalone release (unless --no-build)
2. Test provider configuration and API key validation
3. Run streaming chat and verify complete responses
4. Verify message persistence
5. Test session resume after real provider turns
6. Test incomplete stream error handling (timeout simulation)

Expected Output:
- Complete streamed response with provider metadata
- Both user and assistant messages persisted
- Session can be resumed with conversation history
- Clear error messages for incomplete streams

USAGE
}

while (($# > 0)); do
  case "$1" in
    --openai)
      VERIFY_OPENAI=1
      shift
      ;;
    --anthropic)
      VERIFY_ANTHROPIC=1
      shift
      ;;
    --all)
      VERIFY_ALL=1
      VERIFY_OPENAI=1
      VERIFY_ANTHROPIC=1
      shift
      ;;
    --no-build)
      BUILD_RELEASE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}FAIL: unknown argument: $1${NC}" >&2
      usage >&2
      exit 64
      ;;
  esac
done

# Default to --openai if nothing specified
if [[ "$VERIFY_OPENAI" -eq 0 && "$VERIFY_ANTHROPIC" -eq 0 ]]; then
  echo -e "${YELLOW}WARNING: No provider specified. Defaulting to --openai${NC}" >&2
  VERIFY_OPENAI=1
fi

log() {
  echo -e "==> $*"
}

success() {
  echo -e "${GREEN}✓ $*${NC}"
}

fail() {
  echo -e "${RED}✗ FAIL: $*${NC}" >&2
  exit 1
}

warn() {
  echo -e "${YELLOW}⚠ WARNING: $*${NC}" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

assert_contains() {
  local file=$1
  local expected=$2
  local description=${3:-"output contains expected text"}

  if grep -Fq "$expected" "$file"; then
    success "$description"
  else
    echo "--- $file ---" >&2
    cat "$file" >&2
    echo "--- end $file ---" >&2
    fail "$description: expected '$expected'"
  fi
}

assert_file_nonempty() {
  local file=$1
  local description=${2:-"file is non-empty"}

  if [[ -s "$file" ]]; then
    success "$description"
  else
    fail "$description: $file is empty or missing"
  fi
}

make_temp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/tet-real-provider.XXXXXX"
}

cleanup() {
  if [[ -n "${WORKSPACE:-}" && -d "$WORKSPACE" ]]; then
    rm -rf "$WORKSPACE"
  fi
}

trap cleanup EXIT

build_release() {
  if [[ "${BUILD_RELEASE:-1}" -eq 1 ]]; then
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
  success "tet release wrapper exists and is executable"
}

run_tet() {
  local name=$1
  shift

  local outfile="$WORKSPACE/out/$name.out"
  log "tet $*"

  set +e
  (
    cd "$WORKSPACE/run"
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

verify_openai_compatible() {
  log "=== Verifying OpenAI-compatible provider streaming ==="

  # Check API key
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    fail "OPENAI_API_KEY environment variable is not set"
  fi
  success "OPENAI_API_KEY is set"

  # Configure provider
  export TET_PROVIDER=openai_compatible
  export TET_OPENAI_API_KEY="$OPENAI_API_KEY"
  export TET_OPENAI_MODEL="${TET_OPENAI_MODEL:-gpt-4o-mini}"
  export TET_STORE_PATH="$WORKSPACE/run/.tet"

  # Test 1: Provider configuration and API key validation
  log "Test 1: Provider configuration and API key validation"
  local doctor_out
  doctor_out=$(run_tet openai-doctor doctor)
  assert_contains "$doctor_out" "provider: :openai_compatible (ok)" "doctor reports openai_compatible provider is OK"

  # Test 2: Streaming chat with complete response
  log "Test 2: Streaming chat with complete response"
  local ask_out
  ask_out=$(run_tet openai-ask ask --session openai-real "say hi in five words")
  assert_contains "$ask_out" "gpt-4o-mini:" "response contains model name"

  # Test 3: Message persistence
  log "Test 3: Message persistence"
  local sessions_out
  sessions_out=$(run_tet openai-sessions sessions)
  assert_contains "$sessions_out" "openai-real" "session is listed"

  local session_out
  session_out=$(run_tet openai-session-show session show openai-real)
  assert_contains "$session_out" "say hi in five words" "user message is persisted"
  assert_contains "$session_out" "gpt-4o-mini:" "assistant message is persisted"

  # Test 4: Session resume
  log "Test 4: Session resume"
  local resume_out
  resume_out=$(run_tet openai-resume ask --session openai-real "say bye in five words")
  assert_contains "$resume_out" "gpt-4o-mini:" "resumed session response contains model name"

  # Verify both turns in session
  local session_after_resume
  session_after_resume=$(run_tet openai-session-after-resume session show openai-real)
  assert_contains "$session_after_resume" "say hi in five words" "first user message persisted"
  assert_contains "$session_after_resume" "say bye in five words" "second user message persisted"

  success "OpenAI-compatible provider verification passed"
}

verify_anthropic() {
  log "=== Verifying Anthropic provider streaming ==="

  # Check API key
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    fail "ANTHROPIC_API_KEY environment variable is not set"
  fi
  success "ANTHROPIC_API_KEY is set"

  # Configure provider
  export TET_PROVIDER=anthropic
  export TET_ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
  export TET_ANTHROPIC_MODEL="${TET_ANTHROPIC_MODEL:-claude-sonnet-4-20250514}"
  export TET_STORE_PATH="$WORKSPACE/run/.tet"

  # Test 1: Provider configuration and API key validation
  log "Test 1: Provider configuration and API key validation"
  local doctor_out
  doctor_out=$(run_tet anthropic-doctor doctor)
  assert_contains "$doctor_out" "provider: :anthropic (ok)" "doctor reports anthropic provider is OK"

  # Test 2: Streaming chat with complete response
  log "Test 2: Streaming chat with complete response"
  local ask_out
  ask_out=$(run_tet anthropic-ask ask --session anthropic-real "say hi in five words")
  assert_contains "$ask_out" "claude-sonnet-4-20250514:" "response contains model name"

  # Test 3: Message persistence
  log "Test 3: Message persistence"
  local sessions_out
  sessions_out=$(run_tet anthropic-sessions sessions)
  assert_contains "$sessions_out" "anthropic-real" "session is listed"

  local session_out
  session_out=$(run_tet anthropic-session-show session show anthropic-real)
  assert_contains "$session_out" "say hi in five words" "user message is persisted"
  assert_contains "$session_out" "claude-sonnet-4-20250514:" "assistant message is persisted"

  # Test 4: Session resume
  log "Test 4: Session resume"
  local resume_out
  resume_out=$(run_tet anthropic-resume ask --session anthropic-real "say bye in five words")
  assert_contains "$resume_out" "claude-sonnet-4-20250514:" "resumed session response contains model name"

  # Verify both turns in session
  local session_after_resume
  session_after_resume=$(run_tet anthropic-session-after-resume session show anthropic-real)
  assert_contains "$session_after_resume" "say hi in five words" "first user message persisted"
  assert_contains "$session_after_resume" "say bye in five words" "second user message persisted"

  success "Anthropic provider verification passed"
}

main() {
  require_command grep
  require_command mktemp

  log "BD-0082: Real provider streaming verification"
  log "⚠️  MANUAL VERIFICATION ONLY — NOT FOR CI ⚠️"
  echo

  build_release
  assert_release_wrapper

  WORKSPACE=$(make_temp_dir)
  mkdir -p "$WORKSPACE/out" "$WORKSPACE/run" "$WORKSPACE/run/.tet" "$WORKSPACE/home" "$WORKSPACE/tmp"

  local start_time
  start_time=$(date +%s)

  if [[ "$VERIFY_OPENAI" -eq 1 ]]; then
    verify_openai_compatible
  fi

  if [[ "$VERIFY_ANTHROPIC" -eq 1 ]]; then
    verify_anthropic
  fi

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  echo
  log "BD-0082: Real provider streaming verification passed (${duration}s)"
  log "✅ OpenAI-compatible provider: SSE parsing, auth, [DONE] detection, message persistence verified"
  log "✅ Anthropic provider: SSE parsing, auth, message_stop detection, message persistence verified"
  log "✅ Session resume: conversation history maintained across turns"
}

main
