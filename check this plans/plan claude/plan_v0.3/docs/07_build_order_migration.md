# 07 — Build Order and Migration

## Phase 0 — Skeleton and boundary guards

Deliverables:

- umbrella skeleton;
- apps: `tet_core`, `tet_runtime`, `tet_cli`, `tet_store_memory`, `tet_store_sqlite`;
- optional placeholder `tet_web_phoenix`, excluded from standalone;
- dependency guards, xref guard, source guard, release closure guard;
- first CI workflow;
- explicit forbidden-dependency docs.

Pass condition:

- guards run and fail on deliberate Phoenix import in core/runtime/CLI;
- `mix release tet_standalone` has no Phoenix closure.

## Phase 1 — Core contracts

Build in `tet_core`:

- domain structs;
- command structs;
- event struct and event type list;
- policy modules and reason atoms;
- approval state helpers;
- behaviours: `Tet.Store`, `Tet.Tool`, `Tet.LLM.Provider`;
- redactor;
- ids and errors.

Pass condition:

- `tet_core` compiles with no Phoenix, Plug, Ecto, runtime, CLI, or web references.

## Phase 2 — Runtime foundation and public facade

Build in `tet_runtime`:

- `Tet.Application`;
- `Tet` facade;
- `Tet.Runtime` dispatcher;
- event bus;
- session registry/supervisor/worker;
- store supervisor/dispatcher;
- basic doctor.

Pass condition:

- runtime starts without endpoint;
- facade can create/get a test session using memory store.

## Phase 3 — Storage adapters and workspace init

Build:

- `tet_store_memory` contract test adapter;
- `tet_store_sqlite` migrations and schemas;
- `.tet/` folder creation;
- config loader;
- artifact paths;
- store contract tests shared by memory and sqlite.

Pass condition:

- `tet init .` creates local workspace store;
- events/sessions persist and reload.

## Phase 4 — CLI foundation

Build:

- escript/release entrypoint;
- argv parser;
- renderers;
- `tet doctor`;
- `tet init`;
- `tet workspace trust/info`;
- `tet session new/list/show`.

Pass condition:

- CLI boots and initializes workspace with no Phoenix dependency.

## Phase 5 — Chat mode

Build:

- prompt layers;
- prompt debug;
- one provider adapter;
- streaming provider events;
- message persistence;
- `tet chat`, `tet ask`, `tet prompt debug`.

Pass condition:

- user can chat from terminal;
- messages/events persist;
- provider errors become events/errors and do not crash the runtime.

## Phase 6 — Explore mode and read tools

Build:

- mode enforcement;
- tool registry;
- path resolver;
- `list_dir`, `read_file`, `search_text`, `git_status`, `git_diff`;
- blocked tool persistence;
- `tet explore`; 
- `tet events tail`.

Pass condition:

- inside-root reads work;
- outside-root and symlink escapes are blocked and persisted.

## Phase 7 — Execute mode, patches, approvals

Build:

- active task model;
- `propose_patch`;
- diff artifact storage;
- approval rows;
- `tet edit`;
- `tet approvals`;
- `tet patch approve`;
- `tet patch reject`;
- `apply_approved_patch`.

Pass condition:

- patch is proposed as diff;
- user sees approval in CLI;
- approved patch changes files;
- rejected patch changes nothing;
- untrusted workspace cannot write.

## Phase 8 — Verification loop

Build:

- named verifier allowlist;
- command runner;
- stdout/stderr artifacts;
- timeouts;
- redaction before display;
- `tet verify`;
- `tet status`.

Pass condition:

- approved patch can trigger verifier;
- failed verifier returns exit code 6 and does not corrupt approval state.

## Phase 9 — Hardening

Add tests for:

- path traversal and symlink escapes;
- mode policy matrix;
- untrusted workspace writes;
- patch apply without approval;
- patch no longer applying cleanly;
- oversized read/patch;
- verifier not in allowlist;
- provider/tool failures;
- redaction;
- event ordering;
- no Phoenix dependencies;
- CLI smoke script.

Pass condition:

- full acceptance checklist passes.

## Phase 10 — Optional Phoenix adapter

Only after CLI v1 works.

Build:

- endpoint/router;
- dashboard;
- session timeline;
- transcript;
- tool activity;
- pending approval panel;
- diff preview;
- verifier output;
- prompt debug drawer.

Pass condition:

- Phoenix renders CLI-created sessions;
- Phoenix approves/rejects through `Tet.approve_patch/3` and `Tet.reject_patch/3`;
- no duplicated policy/patch/provider/prompt/verifier logic.

## Phase 11 — Release profiles

Build:

- `tet_standalone`;
- `tet_web`;
- `tet_runtime_only`.

Pass condition:

- standalone release excludes Phoenix/Plug/Cowboy/LiveView;
- web release includes Phoenix only through `tet_web_phoenix`.
