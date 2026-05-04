#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# BD-0084: SQLite Durability & Session Resume Integrity Test
#
# Verifies that the SQLite store correctly persists and retrieves all entity
# types across process restarts using the release binary with a temporary
# store path.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail  # Note: NOT set -e so we can handle failures

TET="/home/adam/tet/_build/prod/rel/tet_standalone/bin/tet"
TET_S="/home/adam/tet/_build/prod/rel/tet_standalone/bin/tet_standalone"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0; SESSION1_ID=""

ok()   { TOTAL=$((TOTAL+1)); echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { TOTAL=$((TOTAL+1)); echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }

check_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

check_contains() {
  local label="$1" text="$2" needle="$3"
  if echo "$text" | grep -qF "$needle"; then ok "$label"
  else fail "$label (missing: '$needle')"
       echo "      Output: $(echo "$text" | head -5)"
  fi
}

check_gt() {
  local label="$1" val="$2" thr="$3"
  if [ "$val" -gt "$thr" ] 2>/dev/null; then ok "$label"; else fail "$label ($val <= $thr)"; fi
}

# Eval helper: starts apps then runs Elixir code
eval_sql() {
  cd "$WORKDIR" && $TET_S eval "Application.ensure_all_started(:tet_store_sqlite); $1" 2>&1
}

echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW} BD-0084: SQLite Durability & Session Resume Integrity Test ${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
echo ""

WORKDIR=$(mktemp -d)
echo "Working directory: $WORKDIR"
echo ""

cleanup() { :; }  # Don't kill BEAMs during the test
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 0: Bootstrap store
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 0: Bootstrap SQLite store${NC}"
OUT=$($TET doctor 2>&1)
check_eq "doctor exits 0" "0" "$?"
check_contains "doctor ok" "$OUT" "store: Tet.Store.SQLite (ok)"
check_contains "doctor WAL" "$OUT" "WAL mode"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1: WAL mode and PRAGMA settings
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 1: WAL mode and PRAGMA settings (pre-restart)${NC}"
P=$(eval_sql 's=Tet.Store.SQLite.Connection.pragma_snapshot!(); IO.puts("jm="<>s.journal_mode<>" sy="<>to_string(s.synchronous)<>" fk="<>to_string(s.foreign_keys)<>" bt="<>to_string(s.busy_timeout)<>" ts="<>to_string(s.temp_store)<>" cs="<>to_string(s.cache_size)<>" mm="<>to_string(s.mmap_size)<>" av="<>to_string(s.auto_vacuum))')
check_eq "eval exit 0" "0" "$?"
check_contains "WAL journal_mode" "$P" "jm=wal"
check_contains "synchronous=1" "$P" "sy=1"
check_contains "foreign_keys=1" "$P" "fk=1"
check_contains "busy_timeout=5000" "$P" "bt=5000"
check_contains "temp_store=2" "$P" "ts=2"
check_contains "cache_size=-20000" "$P" "cs=-20000"
check_contains "auto_vacuum=incremental" "$P" "av=incremental"

W=$(eval_sql 'p=Tet.Store.SQLite.Connection.default_database_path(); wal=p<>"-wal"; shm=p<>"-shm"; IO.puts("wal="<>to_string(File.exists?(wal))<>" shm="<>to_string(File.exists?(shm)))')
check_contains "WAL file on disk" "$W" "wal=true"
check_contains "SHM file on disk" "$W" "shm=true"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2: Create first session with messages
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 2: Create session with messages (BEAM #1)${NC}"
cd "$WORKDIR"
A1=$($TET ask "Hello from BD-0084 test - message one" 2>&1) || true
check_contains "ask#1 returns response" "$A1" "mock:"

sleep 0.3

S1=$($TET sessions 2>&1) || true
check_contains "sessions shows session" "$S1" "messages=2"
SESSION1_ID=$(echo "$S1" | grep -oP 'ses_[A-Za-z0-9_]+' | head -1)
echo "  Session ID: $SESSION1_ID"

if [ -z "$SESSION1_ID" ]; then
  echo -e "${RED}FATAL: Could not extract session ID from: $S1${NC}"
  exit 1
fi

# Small wait for WAL to settle
sleep 0.2

SH=$($TET session show "$SESSION1_ID" 2>&1) || true
check_contains "session show returns content" "$SH" "Messages:"
check_contains "user msg persisted" "$SH" "Hello from BD-0084 test - message one"
check_contains "assistant msg persisted" "$SH" "mock:"

EV=$($TET events --session "$SESSION1_ID" 2>&1) || true
check_contains "events have #1" "$EV" "#1 "
check_contains "events have #2" "$EV" "#2 "
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3: Resume session with second message
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 3: Resume session (BEAM #2)${NC}"
cd "$WORKDIR"
A2=$($TET ask --session "$SESSION1_ID" "Second message from BD-0084" 2>&1) || true
check_contains "ask#2 returns response" "$A2" "mock:"

sleep 0.3

SH2=$($TET session show "$SESSION1_ID" 2>&1) || true
check_contains "4 messages after resume" "$SH2" "messages: 4"
check_contains "msg1 survived" "$SH2" "Hello from BD-0084 test - message one"
check_contains "msg2 persisted" "$SH2" "Second message from BD-0084"
check_contains "asst1 survived" "$SH2" "mock: Hello from BD-0084 test - message one"
check_contains "asst2 persisted" "$SH2" "mock: Second message from BD-0084"

EV2=$($TET events --session "$SESSION1_ID" 2>&1) || true
check_contains "seq continued (>=11)" "$EV2" "#11 "
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4: Autosave checkpoint
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 4: Autosave creation and restoration${NC}"
AS=$(eval_sql 'alias Tet.Store.SQLite; sid="'"$SESSION1_ID"'"; {:ok, msgs} = SQLite.list_messages(sid, []); a = %Tet.Autosave{checkpoint_id: "cp_bd0084_", session_id: sid, saved_at: DateTime.utc_now()|>DateTime.to_iso8601(), messages: msgs, attachments: [], prompt_metadata: %{"test"=>"bd0084"}, prompt_debug: %{"phase"=>"4"}, prompt_debug_text: "BD-0084 durability test", metadata: %{"source"=>"test"}}; {:ok, s} = SQLite.save_autosave(a, []); IO.puts("as_msgs="<>to_string(length(s.messages))); IO.puts("as_sid="<>s.session_id); {:ok, l} = SQLite.load_autosave(sid, []); IO.puts("ld_msgs="<>to_string(length(l.messages))); IO.puts("ld_src="<>to_string(Map.get(l.metadata, "source"))); IO.puts("ld_txt="<>l.prompt_debug_text)')
check_contains "autosave has 4 msgs" "$AS" "as_msgs=4"
check_contains "autosave sid correct" "$AS" "as_sid=$SESSION1_ID"
check_contains "load msgs match" "$AS" "ld_msgs=4"
check_contains "load metadata ok" "$AS" "ld_src=test"
check_contains "load text ok" "$AS" "ld_txt=BD-0084 durability test"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5: Checkpoint creation
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 5: Checkpoint creation${NC}"
CP=$(eval_sql 'alias Tet.Store.SQLite; sid="'"$SESSION1_ID"'"; {:ok, c} = SQLite.save_checkpoint(%{id: "ckpt_bd0084_", session_id: sid, sha256: "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb", state_snapshot: %{"turn"=>3}, metadata: %{"test"=>"bd0084"}}, []); IO.puts("cp_id="<>c.id); IO.puts("cp_sid="<>c.session_id); IO.puts("cp_sha="<>String.slice(c.sha256, 0, 16)); {:ok, cps} = SQLite.list_checkpoints(sid, []); IO.puts("cp_count="<>to_string(length(cps)))')
check_contains "checkpoint id ok" "$CP" "cp_id=ckpt_bd0084_"
check_contains "checkpoint sid ok" "$CP" "cp_sid=$SESSION1_ID"
check_contains "checkpoint sha ok" "$CP" "cp_sha=ca978112ca1bb"
check_contains "at least 1 checkpoint" "$CP" "cp_count=1"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 6: Kill BEAM and restart — verify survival
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 6: Kill BEAM, restart, verify data survival${NC}"
cd "$WORKDIR"
sleep 0.5

RS=$($TET sessions 2>&1) || true
check_contains "session survived restart" "$RS" "$SESSION1_ID"
check_contains "4 msgs survived" "$RS" "messages=4"

RSS=$($TET session show "$SESSION1_ID" 2>&1) || true
check_contains "msg1 survived restart" "$RSS" "Hello from BD-0084 test - message one"
check_contains "msg2 survived restart" "$RSS" "Second message from BD-0084"

RSE=$($TET events --session "$SESSION1_ID" 2>&1) || true
check_contains "events survived (has #1)" "$RSE" "#1 "
check_contains "events survived (has #11)" "$RSE" "#11 "
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 7: WAL mode and PRAGMAs survive restart
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 7: PRAGMAs survive restart${NC}"
RP=$(eval_sql 's=Tet.Store.SQLite.Connection.pragma_snapshot!(); IO.puts("jm="<>s.journal_mode<>" sy="<>to_string(s.synchronous)<>" fk="<>to_string(s.foreign_keys)<>" bt="<>to_string(s.busy_timeout))')
check_contains "WAL persists" "$RP" "jm=wal"
check_contains "sync persists" "$RP" "sy=1"
check_contains "FK persists" "$RP" "fk=1"
check_contains "busy persists" "$RP" "bt=5000"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 8: Autosave survived restart
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 8: Autosave survived restart${NC}"
RAS=$(eval_sql 'alias Tet.Store.SQLite; {:ok, l} = SQLite.load_autosave("'"$SESSION1_ID"'", []); IO.puts("ld_msgs="<>to_string(length(l.messages))<>" ld_src="<>to_string(Map.get(l.metadata, "source"))<>" ld_txt="<>l.prompt_debug_text)')
check_contains "autosave msgs survived" "$RAS" "ld_msgs=4"
check_contains "autosave metadata survived" "$RAS" "ld_src=test"
check_contains "autosave text survived" "$RAS" "ld_txt=BD-0084 durability test"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 9: Session summary derived from stored messages
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 9: Session summary from stored messages${NC}"
SS=$(eval_sql 'alias Tet.Store.SQLite; {:ok, s} = SQLite.fetch_session("'"$SESSION1_ID"'", []); IO.puts("mc="<>to_string(s.message_count)); IO.puts("mode="<>to_string(s.mode)); {:ok, msgs} = SQLite.list_messages("'"$SESSION1_ID"'", []); IO.puts("actual="<>to_string(length(msgs))); {:ok, sl} = SQLite.list_sessions([]); t = Enum.find(sl, &(&1.id=="'"$SESSION1_ID"'")); IO.puts("lc="<>to_string(t.message_count)); IO.puts("lr="<>to_string(t.last_role))')
check_contains "message_count=4" "$SS" "mc=4"
check_contains "actual count=4" "$SS" "actual=4"
check_contains "list summary=4" "$SS" "lc=4"
check_contains "last_role=assistant" "$SS" "lr=assistant"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 10: Event sequence numbers correct
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 10: Event sequence numbers${NC}"
SQ=$(eval_sql 'alias Tet.Store.SQLite; {:ok, evts} = SQLite.list_events("'"$SESSION1_ID"'", []); seqs = Enum.map(evts, & &1.seq); n = length(seqs); sorted = Enum.sort(seqs); IO.puts("total="<>to_string(n)); IO.puts("mono="<>to_string(seqs==sorted)); IO.puts("nogaps="<>to_string(sorted==Enum.to_list(1..n))); IO.puts("max="<>to_string(Enum.max(seqs)))')
TOT=$(echo "$SQ" | grep -oP 'total=\K[0-9]+' || echo "0")
check_gt ">=10 events" "$TOT" 10
check_contains "monotonic" "$SQ" "mono=true"
check_contains "no gaps" "$SQ" "nogaps=true"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 11: Concurrent read access
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 11: Concurrent read access${NC}"
CR=$(eval_sql 'alias Tet.Store.SQLite; sid="'"$SESSION1_ID"'"; tasks = for i <- 1..5 do Task.async(fn -> s=System.monotonic_time(:millisecond); {:ok, se} = SQLite.fetch_session(sid, []); {:ok, m} = SQLite.list_messages(sid, []); {:ok, e} = SQLite.list_events(sid, []); %{i: i, ok: se.id==sid, mc: length(m), ec: length(e), ms: System.monotonic_time(:millisecond)-s} end) end; r = Task.await_many(tasks, 10000); IO.puts("all_ok="<>to_string(Enum.all?(r, & &1.ok))); IO.puts("all_mc4="<>to_string(Enum.all?(r, & &1.mc==4))); IO.puts("max_ms="<>to_string(r |> Enum.map(& &1.ms) |> Enum.max()))')
check_contains "all tasks ok" "$CR" "all_ok=true"
check_contains "all msg count 4" "$CR" "all_mc4=true"
MAX_MS=$(echo "$CR" | grep -oP 'max_ms=\K[0-9]+' || echo "0")
TOTAL=$((TOTAL+1))
if [ "$MAX_MS" -gt 2000 ] 2>/dev/null; then
  fail "concurrent reads blocked (${MAX_MS}ms)"
else
  echo -e "  ${GREEN}✓${NC} concurrent reads fast (${MAX_MS}ms)"
  PASS=$((PASS+1))
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 12: Direct SQLite file inspection
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 12: Direct SQLite file inspection${NC}"
FC=$(eval_sql 'p=Tet.Store.SQLite.Connection.default_database_path(); {:ok, st} = File.stat(p); IO.puts("exists=true size="<>to_string(st.size)); {_, %{rows: [[cnt]]}} = Ecto.Adapters.SQL.query(Tet.Store.SQLite.Repo, "SELECT COUNT(*) FROM sqlite_master WHERE type = ?", ["table"]); IO.puts("tables="<>to_string(cnt)); {_, %{rows: [[j]]}} = Ecto.Adapters.SQL.query(Tet.Store.SQLite.Repo, "PRAGMA journal_mode", []); IO.puts("journal="<>to_string(j)); {_, %{rows: [[i]]}} = Ecto.Adapters.SQL.query(Tet.Store.SQLite.Repo, "PRAGMA integrity_check", []); IO.puts("integrity="<>to_string(i))')
check_contains "DB file exists" "$FC" "exists=true"
check_contains "integrity ok" "$FC" "integrity=ok"
check_contains "WAL on file" "$FC" "journal=wal"
TBL=$(echo "$FC" | grep -oP 'tables=\K[0-9]+' || echo "0")
check_gt "has tables" "$TBL" 10
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 13: Write after restart (no corruption)
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 13: Write after restart (no corruption)${NC}"
cd "$WORKDIR"
A3=$($TET ask --session "$SESSION1_ID" "Third msg after durability check" 2>&1) || true
check_contains "ask#3 returns" "$A3" "mock:"

sleep 0.3
SH3=$($TET session show "$SESSION1_ID" 2>&1) || true
check_contains "6 msgs now" "$SH3" "messages: 6"
check_contains "third msg persisted" "$SH3" "Third msg after durability check"

EV3=$($TET events --session "$SESSION1_ID" 2>&1) || true
check_contains "events continued (>=21)" "$EV3" "#21 "
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 14: Session summary updated after new writes
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 14: Session summary updated after new writes${NC}"
SS2=$(eval_sql 'alias Tet.Store.SQLite; {:ok, s} = SQLite.fetch_session("'"$SESSION1_ID"'", []); IO.puts("mc="<>to_string(s.message_count)); {:ok, msgs} = SQLite.list_messages("'"$SESSION1_ID"'", []); IO.puts("actual="<>to_string(length(msgs))); IO.puts("lr="<>to_string(s.last_role))')
check_contains "message_count=6" "$SS2" "mc=6"
check_contains "actual count=6" "$SS2" "actual=6"
check_contains "last_role=assistant" "$SS2" "lr=assistant"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 15: Prompt Lab history entries survive restart
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}Phase 15: Prompt Lab history survives restart${NC}"
PLH=$(eval_sql 'alias Tet.Store.SQLite; {:ok, req} = Tet.PromptLab.Request.new(%{prompt: "BD-0084 prompt lab test", preset_id: "coding"}); {:ok, ref} = Tet.PromptLab.refine("BD-0084 prompt lab test", preset: "coding", refinement_id: "ref-bd0084-plab"); {:ok, entry} = Tet.PromptLab.HistoryEntry.new(%{id: "ph_bd0084_plab_test", created_at: DateTime.utc_now() |> DateTime.to_iso8601(), request: req, result: ref, metadata: %{"source" => "bd0084"}}); {:ok, saved} = SQLite.save_prompt_history(entry, []); IO.puts("saved_id=" <> saved.id); IO.puts("saved_preset=" <> saved.request.preset_id)')
check_contains "prompt history saved" "$PLH" "saved_id=ph_bd0084_plab_test"
check_contains "prompt history preset" "$PLH" "saved_preset=coding"

sleep 0.3

PLH2=$(eval_sql 'alias Tet.Store.SQLite; {:ok, fetched} = SQLite.fetch_prompt_history("ph_bd0084_plab_test", []); IO.puts("fetched_id=" <> fetched.id); IO.puts("fetched_preset=" <> fetched.request.preset_id); IO.puts("fetched_src=" <> to_string(Map.get(fetched.metadata, "source"))); {:ok, listed} = SQLite.list_prompt_history([]); IO.puts("list_count=" <> to_string(length(listed))); match = Enum.find(listed, &(&1.id == "ph_bd0084_plab_test")); IO.puts("found_in_list=" <> to_string(match != nil))')
check_contains "prompt history survived" "$PLH2" "fetched_id=ph_bd0084_plab_test"
check_contains "prompt history preset ok" "$PLH2" "fetched_preset=coding"
check_contains "prompt history metadata ok" "$PLH2" "fetched_src=bd0084"
check_contains "prompt history in list" "$PLH2" "found_in_list=true"
check_gt "list has entries" "$(echo "$PLH2" | grep -oP 'list_count=\K[0-9]+' || echo '0')" 0
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN} ALL $TOTAL CHECKS PASSED ✓${NC}"
else
  echo -e "${RED} $FAIL/$TOTAL CHECKS FAILED ✗${NC}"
fi
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"

# Cleanup
rm -rf "$WORKDIR" 2>/dev/null || true

exit $FAIL
