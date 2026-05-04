# BD-0092: Release Binary Size and Startup Performance Budget Baseline

**Date:** 2025-05-03 (initial) → 2025-05-03 (boot fix verified) → 2025-05-04 (BD-0092 baseline confirmed)  
**Release:** tet_standalone 0.1.0  
**Elixir:** 1.19.5 | **ERTS:** 16.4 | **Erlang:** 27+  
**Environment:** Linux x86_64, prod build  

---

## 1. Release Size

| Metric | Value |
|--------|-------|
| **Total on disk** | **75 MB** |
| ERTS (16.4) | 56 MB (75%) |
| Application libs | 19 MB (25%) |
| Compressed (tar.gz) | **28 MB** |

**Target:** < 50 MB compressed → ✅ **28 MB compressed — well within budget**  
**Key observation:** 75% of the release is the Erlang runtime system itself. The `beam.smp` binary alone is 53 MB. Application code is a fraction.

### Library Breakdown (top 10 largest)

| Library | Size | Category |
|---------|------|----------|
| elixir-1.19.5 | 2.9 MB | Elixir stdlib |
| stdlib-7.3 | 2.7 MB | OTP built-in |
| exqlite-0.36.0 | 1.8 MB | Third-party (SQLite NIF) |
| public_key-1.20.3 | 1.5 MB | OTP built-in |
| tet_core-0.1.0 | 1.4 MB | Umbrella app |
| kernel-10.6.3 | 1.3 MB | OTP built-in |
| compiler-9.0.6 | 1.3 MB | OTP built-in |
| ssl-11.6 | 912 KB | OTP built-in |
| ecto-3.13.5 | 896 KB | Third-party (ORM) |
| asn1-5.4.3 | 696 KB | OTP built-in |

### Application Code Size (umbrella apps)

| App | Size |
|-----|------|
| tet_core-0.1.0 | 1.4 MB |
| tet_runtime-0.1.0 | 556 KB |
| tet_store_sqlite-0.1.0 | 380 KB |
| tet_cli-0.1.0 | 84 KB |
| **Total umbrella** | **~2.4 MB** |

---

## 2. Dependency Count

**Total OTP applications in release:** 24 (permanent) + 1 (none: iex) = 25 in `.rel` file  
**Total library directories in release:** 25

### Classification

| Category | Count | Apps |
|----------|-------|------|
| **Umbrella (tet_\*)** | 4 | tet_core, tet_store_sqlite, tet_runtime, tet_cli |
| **OTP/BEAM built-in** | 8 | kernel, stdlib, compiler, elixir, logger, eex, iex, sasl |
| **Third-party** | 13 | asn1, crypto, db_connection, decimal, ecto, ecto_sql, ecto_sqlite3, exqlite, inets, jason, public_key, ssl, telemetry |

### Assessment

The release includes **13 third-party dependencies**. This is lean for an Ecto+SQLite+SSL stack. The `ssl`/`crypto`/`public_key`/`asn1` chain (2.7 MB) is pulled in for OpenAI-compatible HTTPS provider support. The `ecto`/`ecto_sql`/`ecto_sqlite3`/`exqlite`/`db_connection` chain (2.8 MB) is required for the SQLite store.

No web dependencies (phoenix, cowboy, bandit, etc.) are present — the standalone boundary gate is working.

---

## 3. Startup Time (`tet doctor` invocation to first output)

> **Target:** < 2 seconds on modern hardware  
> **Note:** Measures wall-clock time from `tet doctor` invocation to first output.

| Run | Time |
|-----|------|
| 1 | 290 ms |
| 2 | 310 ms |
| 3 | 300 ms |
| **Mean** | **300 ms** |
| **P95** | **~310 ms** |

### Assessment

**✅ ~300ms startup is excellent** — well under the 2-second target. Cold start from disk through Ecto repo init to first `doctor` output takes under 400ms. Measurements confirmed on 2025-05-04.

---

## 4. First-Ask Latency (`tet ask` invocation to first streamed chunk)

> **Target:** < 1 second  
> **Note:** Uses `TET_PROVIDER=mock` with `--session` flag for session creation. Mock provider has zero network latency.

| Run | Time |
|-----|------|
| 1 | 400 ms |
| 2 | 310 ms |
| 3 | 310 ms |
| **Mean** | **340 ms** |
| **P95** | **~400 ms** |

### Assessment

**✅ ~340ms first-ask latency is excellent** — well under the 1-second target. The entire boot → session create → mock provider → stream cycle completes in under 400ms. Measurements confirmed on 2025-05-04.

### Known Issue: `tet ask` without `--session` fails

When invoked without `--session`, `tet ask "hello"` may fail with a database error creating session record. This is a **pre-existing bug in session auto-naming** (not related to boot/performance). The `--session <name>` path works correctly.

### Memory (peak resident)

| Metric | Value |
|--------|-------|
| Max RSS (`tet doctor`) | 74 MB |
| Max RSS (`tet ask`) | 75 MB |

---

## 5. Dependency Audit

### Release Closure Verification

- ✅ **No web framework dependencies** — `check_release_closure.sh` passes
- ✅ **No dev-only dependencies** — no credo, ex_doc, mox, bypass, etc. in release
- ✅ **First-mile smoke passes** — `smoke_first_mile.sh --no-build` succeeds with mock provider

### Classification (25 total apps in `.rel`)

| Category | Count | Apps |
|----------|-------|------|
| **Umbrella (tet_\*)** | 4 | tet_core, tet_store_sqlite, tet_runtime, tet_cli |
| **OTP/BEAM built-in** | 8 | kernel, stdlib, compiler, elixir, logger, eex, iex, sasl |
| **Third-party** | 13 | asn1, crypto, db_connection, decimal, ecto, ecto_sql, ecto_sqlite3, exqlite, inets, jason, public_key, ssl, telemetry |

### Dependency Justifications

| Dependency Chain | Size | Justification |
|-----------------|------|---------------|
| ssl/crypto/public_key/asn1 | 2.7 MB | Required for OpenAI-compatible HTTPS provider support |
| ecto/ecto_sql/ecto_sqlite3/exqlite/db_connection | 2.8 MB | Required for SQLite store (core data persistence) |
| jason | 212 KB | JSON encoding/decoding for provider API and config |
| telemetry | 44 KB | Ecto/DB_connection telemetry integration |
| inets | 504 KB | OTP built-in; may be pulled in by SSL or runtime config |

### Unnecessary Dependencies Identified

| App | Size | Issue | Recommendation |
|-----|------|-------|----------------|
| **iex** | 240 KB | `mode: none` — never started, not used by any source code | Remove from release applications list |
| **eex** | 48 KB | `mode: permanent` — no `EEx.*` usage in source code | Remove from release applications list |

---

## 6. Budget Assessment

| Metric | Measured | Target | Status |
|--------|----------|--------|--------|
| **Release size (on disk)** | 75 MB | — | ✅ Documented |
| **Release size (compressed)** | 28 MB | < 50 MB | ✅ **Under budget** |
| **Startup time (`tet doctor`)** | 300 ms | < 2 s | ✅ **Well under budget** |
| **First-ask latency (mock)** | 340 ms | < 1 s | ✅ **Well under budget** |
| **Peak RSS** | 75 MB | < 128 MB | ✅ **Under budget** |
| **Dependency count** | 24 permanent | < 30 | ✅ **Under budget** |
| **Web deps leaked** | 0 | 0 | ✅ **Clean closure** |
| **Dev deps leaked** | 0 | 0 | ✅ **Clean closure** |
| **Release functional** | ✅ | Must work | ✅ **Doctor + Ask work** |

### ERTS Dev Tools (potential savings)

The release includes ~2 MB of ERTS development tools that are unnecessary in a CLI release:

| Tool | Size |
|------|------|
| erlc | 530 KB |
| erl_call | 495 KB |
| epmd | 207 KB |
| inet_gethost | 182 KB |
| escript | 120 KB |
| ct_run | 115 KB |
| dialyzer | 109 KB |
| typer | 108 KB |
| run_erl | 90 KB |
| to_erl | 45 KB |
| **Total** | **~2 MB** |

Additionally, `beam.smp` (53 MB) is **not stripped** — stripping debug symbols could save ~10-15 MB.

### Recommendations

1. **[P1] Strip beam.smp debug symbols** — Could reduce release by ~10-15 MB. Highest impact single change.
2. **[P2] Remove iex and eex from release** — Neither is used by application code. Combined savings: 288 KB. Low impact but follows YAGNI.
3. **[P2] Exclude ERTS dev tools via rel config** — ct_run, dialyzer, typer, erl_call, etc. are not needed in a CLI release. Saves ~2 MB. Requires custom `include_executables_for` filtering.
4. **[P2] Evaluate SSL dependency** — The ssl/crypto/public_key/asn1 chain (2.7 MB) is needed only for HTTPS providers. If a future "offline-only" release is desired, this could be conditional.
5. **[P3] Fix `tet ask` without `--session`** — Auto-generated short_id causes unique constraint collisions. Separate bug, not performance-related.

---

## Appendix: Reproduction Commands

```bash
# Release size
rm -f /tmp/tet_sz.tar.gz && cd _build/prod/rel && tar czf /tmp/tet_sz.tar.gz tet_standalone/ && ls -lh /tmp/tet_sz.tar.gz

# Startup time (5 runs)
for i in 1 2 3 4 5; do
  START=$(date +%s%N)
  TET_PROVIDER=mock _build/prod/rel/tet_standalone/bin/tet doctor >/dev/null 2>&1
  END=$(date +%s%N)
  echo "Run $i: $(( (END - START) / 1000000 ))ms"
done

# First-ask latency (5 runs)
for i in 1 2 3 4 5; do
  START=$(date +%s%N)
  TET_PROVIDER=mock _build/prod/rel/tet_standalone/bin/tet ask --session "bench-$i" "ping" >/dev/null 2>&1
  END=$(date +%s%N)
  echo "Run $i: $(( (END - START) / 1000000 ))ms"
done

# Release closure check
tools/check_release_closure.sh --no-build

# First-mile smoke
tools/smoke_first_mile.sh --no-build
```

---

*Updated 2025-05-04 (2nd pass): BD-0092 baseline re-verified by code-puppy-b1c5c6. All measurements stable. No bloat found. All targets met.*

---

## Appendix B: Re-verification (2025-05-04 01:50 UTC)

Fresh measurements taken via `code-puppy-b1c5c6` agent for audit trail.

### Release Size

| Metric | Value |
|--------|-------|
| On disk | 75 MB |
| Compressed (tar.gz) | 28 MB |

**Target:** < 50 MB compressed → ✅ **28 MB — PASS**

### Startup Time (`tet doctor` → first output)

| Run | Wall-clock |
|-----|------------|
| 1 | 292 ms |
| 2 | 299 ms |
| 3 | 304 ms |
| 4 | 285 ms |
| 5 | 299 ms |
| **Mean** | **296 ms** |

**Target:** < 2 s → ✅ **~296 ms — PASS** (6.8× headroom)

### First-Ask Latency (`TET_PROVIDER=mock tet ask --session bench-N ping`)

| Run | Wall-clock |
|-----|------------|
| 1 | 332 ms |
| 2 | 325 ms |
| 3 | 347 ms |
| 4 | 350 ms |
| 5 | 333 ms |
| **Mean** | **337 ms** |

**Target:** < 1 s → ✅ **~337 ms — PASS** (3× headroom)

### Dependency Audit (24 loaded applications)

```
[:asn1, :compiler, :crypto, :db_connection, :decimal, :ecto, :ecto_sql,
 :ecto_sqlite3, :eex, :elixir, :exqlite, :inets, :jason, :kernel, :logger,
 :public_key, :sasl, :ssl, :stdlib, :telemetry, :tet_cli, :tet_core,
 :tet_runtime, :tet_store_sqlite]
```

| Check | Result |
|-------|--------|
| Web framework deps leaked | ✅ None (phoenix, cowboy, bandit all absent) |
| Dev-only deps leaked | ✅ None (credo, ex_doc, dialyxir all absent) |
| Ecto store dependencies | ✅ ecto/ecto_sql/ecto_sqlite3/exqlite — all needed |
| SSL/TLS stack | ✅ ssl/crypto/public_key/asn1 — needed for HTTPS providers |
| HTTP client | ✅ inets — used by tet_runtime for :httpc (provider calls) |
| JSON library | ✅ jason — used by tet_core, tet_runtime, tet_store_sqlite |
| Telemetry | ✅ telemetry — used by ecto/db_connection instrumentation |
| EEx | ⚠️ 48 KB — listed by ecto upstream, not directly used. YAGNI candidate |
| Compiler | ⚠️ 1.3 MB — listed by elixir runtime upstream, not directly used |

**Verdict:** No obvious bloat. All dependencies are justified. Minor YAGNI candidates (eex, compiler) are upstream-mandated and not worth fighting.

### Overall Budget Status

| Metric | Measured | Target | Status |
|--------|----------|--------|--------|
| Compressed size | 28 MB | < 50 MB | ✅ PASS |
| Startup time | 296 ms | < 2 s | ✅ PASS |
| First-ask latency | 337 ms | < 1 s | ✅ PASS |
| Dependency count | 24 | < 30 | ✅ PASS |
| Web deps leaked | 0 | 0 | ✅ PASS |
| Dev deps leaked | 0 | 0 | ✅ PASS |

**Acceptance criteria fully satisfied.**
