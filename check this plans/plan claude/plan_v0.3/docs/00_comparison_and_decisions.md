# 00 — Comparison and Final Decisions

## Source-plan comparison

| Dimension | GPT / Tet plan | Claude / Agent plan | Final decision |
|---|---|---|---|
| Product identity | Uses `Tet`, `tet`, `.tet/` consistently. | Uses `Agent`, `agent`, `.agent/`. | **Use `Tet`, `tet`, `.tet/`**. A top-level `Agent` module conflicts with Elixir's built-in `Agent`. |
| Project shape | Umbrella/multi-app preferred. | Umbrella from day zero. | **Umbrella from day zero**. Do not start single-app and extract later. |
| Core/runtime boundary | `tet_core` pure; `tet_runtime` owns OTP runtime and public API. | Says core is pure, but places public `Agent` facade in core while delegating to runtime. | **Public `Tet` facade lives in `tet_runtime`**. `tet_core` must not reference `Tet.Runtime`. |
| CLI product | Strong concise command list. | More complete command behavior, modes, exit codes. | **Use GPT naming + Claude detail**. |
| Storage | Embedded store, local `.tet/tet.sqlite`, optional Postgres. | Memory/SQLite/Postgres adapters with contract testing. | **Use `tet_store_memory`, `tet_store_sqlite`, optional `tet_store_postgres`**. SQLite is default standalone. |
| Policy/safety | Good patch-only, approval, verifier, redaction outline. | Deeper path policy, policy reason atoms, limits, blocked-action logging. | **Use Claude's safety details under Tet names**. |
| Event bus | Core-owned bus; avoid Phoenix.PubSub. | Registry-based bus; avoid Phoenix.PubSub. | **Registry or `:pg` owned by `tet_runtime`; no Phoenix.PubSub in runtime.** |
| Phoenix | Optional module; shallow LiveViews. | Optional driving adapter; detailed acceptance tests. | **Optional adapter only, built after CLI.** |
| CI enforcement | xref/source/release checks sketched. | Five gates and removability tests. | **Adopt five gates and add facade-only UI guard.** |
| Risk analysis | Mostly acceptance checklist. | Explicit risks and mitigations. | **Keep a risk register.** |

## Final merged rule

```text
Tet must run through Elixir/OTP, not through Phoenix.
Phoenix may render and control Tet, but Phoenix must never own Tet.
```

## Critical corrections made during synthesis

### 1. Do not use `Agent` as the root namespace

`Agent` is already a core Elixir abstraction. A public `Agent` module would be confusing, risky in imports, and painful in docs and stack traces. The final plan uses:

```text
CLI binary:       tet
Root namespace:   Tet
Workspace dir:    .tet/
Runtime app:      tet_runtime
Core app:         tet_core
```

### 2. Do not put the facade in core if it delegates to runtime

A facade in `tet_core` that calls `Tet.Runtime.*` creates an outward dependency from core to runtime. That violates the main architecture. The corrected placement is:

```text
apps/tet_runtime/lib/tet.ex       # public facade
apps/tet_core/lib/tet/*.ex        # pure structs, behaviours, policies, commands, events
```

UIs depend on `tet_runtime` and call `Tet.*`. Storage adapters depend only on `tet_core`.

### 3. Make storage adapters explicit

Use concrete adapters instead of a vague `embedded` app name:

```text
tet_store_memory      tests and fast contract checks
tet_store_sqlite      default standalone local store
tet_store_postgres    optional server/team store, not v1-critical
```

### 4. Build guards before features

Boundary guards are Phase 0, not a cleanup task. The architecture is considered real only when CI proves:

- standalone release has no Phoenix/Plug/Cowboy/Phoenix.LiveView closure;
- no forbidden imports or xref edges exist;
- runtime boots without any endpoint;
- CLI and Phoenix, when present, use only `Tet.*` facade calls;
- removing `tet_web_phoenix` does not break the CLI/runtime tests.

## Final architecture statement

The ultimate plan is a **CLI-first, local-first, patch-safe coding-agent runtime** built as an Elixir umbrella:

```text
tet_core          pure domain contracts, structs, events, policies, behaviours
tet_runtime       OTP supervision, public Tet facade, sessions, event bus, tools, providers
tet_cli           standalone CLI and terminal rendering
tet_store_memory  test adapter
tet_store_sqlite  default local SQLite adapter
tet_store_postgres optional server/team adapter
tet_web_phoenix   optional Phoenix LiveView adapter, never required
```

The v1 product is done when `tet_standalone` can initialize a workspace, create sessions, chat, explore, propose patch diffs, wait for approval, apply approved patches, run allowlisted verification, persist a durable timeline, and ship with zero Phoenix dependencies.
