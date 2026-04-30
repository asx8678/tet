# BD-0038 Profile parity matrix

Issue: `tet-db6.38` / `BD-0038`
Phase: 11 — Code Puppy specialized profile parity
Category: researching
Status: research deliverable; no runtime/profile implementation in this change

## Scope and inspection notes

This matrix maps Code Puppy source agents and adjacent specialty surfaces to Tet
profile descriptors, bounded workers, or explicit deferrals. It is intentionally
behavior-level parity, not a copy/paste prompt migration. Profiles in Tet are
data overlays, not runtime subclasses; workers are reserved for external process,
worktree, browser, merge, daemon, or other lifecycle-owning capabilities.

The isolated `tet-db6.38` worktree does not contain the `source/` checkout, so the
Code Puppy evidence was inspected from the sibling checkout at
`../tet/source/code_puppy-main` while citing the canonical repository-relative
paths below. If reproducing from this worktree, either check out
`source/code_puppy-main` here or point verification scripts at that sibling path.
Tet evidence was inspected in this worktree.

## Tet target baseline inspected

Current Tet implements only the generic profile infrastructure and three bundled
profiles. Specialty profile IDs below are therefore planned/deferred unless the
row explicitly says the baseline already exists.

- `apps/tet_runtime/priv/profile_registry.json` currently declares only
  `tet_standalone`, `chat`, and `tool_use`.
- `apps/tet_runtime/priv/model_registry.json` pins models only for those three
  profiles.
- `apps/tet_core/lib/tet/profile_registry.ex` defines profile descriptors with
  `prompt`, `tool`, `model`, `task`, `schema`, and `cache` overlays.
- `apps/tet_core/lib/tet/profile_registry/validator.ex` requires every profile
  descriptor to expose all six overlay kinds and validates model/profile-pin,
  default-mode, cache-policy, and allow/deny consistency.
- `apps/tet_runtime/lib/tet/runtime/profile_registry.ex` is IO glue for loading
  and validating editable registry JSON; it does not call providers or tools.
- `apps/tet_runtime/lib/tet/runtime/state.ex` models active profile refs,
  turn-boundary swaps, queued/rejected mid-turn swaps, and cache preservation or
  dropping.
- `apps/tet_core/lib/tet/tool/read_only_contracts.ex` defines current read-only
  contracts: `list`, `read`, `search`, `repo-scan`, `git-diff`, and `ask-user`.
- `docs/adr/0004-universal-agent-runtime-boundary.md` says Code Puppy-style named
  agents map to data profiles over one Universal Agent Runtime.
- `docs/adr/0005-gates-approvals-verification.md` says every tool/write/execute,
  remote, MCP, repair, config, or secret-affecting intent goes through one
  runtime-owned gate pipeline.
- `docs/adr/0008-repair-and-error-recovery.md` defines Tet repair as a gated
  recovery workflow, not hidden self-modification.

## Code Puppy source inventory inspected

Primary registry/custom-agent sources:

- `source/code_puppy-main/code_puppy/agents/agent_manager.py`
- `source/code_puppy-main/code_puppy/agents/json_agent.py`
- `source/code_puppy-main/code_puppy/config.py` for `PACK_AGENT_NAMES`,
  `UC_AGENT_NAMES`, and feature flags that hide pack/UC agents.

Top-level agent modules inspected:

- `source/code_puppy-main/code_puppy/agents/agent_code_puppy.py`
- `source/code_puppy-main/code_puppy/agents/agent_planning.py`
- `source/code_puppy-main/code_puppy/agents/prompt_reviewer.py`
- `source/code_puppy-main/code_puppy/agents/agent_code_reviewer.py`
- `source/code_puppy-main/code_puppy/agents/agent_python_reviewer.py`
- `source/code_puppy-main/code_puppy/agents/agent_javascript_reviewer.py`
- `source/code_puppy-main/code_puppy/agents/agent_typescript_reviewer.py`
- `source/code_puppy-main/code_puppy/agents/agent_golang_reviewer.py`
- `source/code_puppy-main/code_puppy/agents/agent_c_reviewer.py`
- `source/code_puppy-main/code_puppy/agents/agent_cpp_reviewer.py`
- `source/code_puppy-main/code_puppy/agents/agent_python_programmer.py`
- `source/code_puppy-main/code_puppy/agents/agent_qa_expert.py`
- `source/code_puppy-main/code_puppy/agents/agent_qa_kitten.py`
- `source/code_puppy-main/code_puppy/agents/agent_terminal_qa.py`
- `source/code_puppy-main/code_puppy/agents/agent_security_auditor.py`
- `source/code_puppy-main/code_puppy/agents/agent_creator_agent.py`
- `source/code_puppy-main/code_puppy/agents/agent_helios.py`
- `source/code_puppy-main/code_puppy/agents/agent_scheduler.py`
- `source/code_puppy-main/code_puppy/agents/agent_pack_leader.py`

Pack subpackage inspected:

- `source/code_puppy-main/code_puppy/agents/pack/__init__.py`
- `source/code_puppy-main/code_puppy/agents/pack/bloodhound.py`
- `source/code_puppy-main/code_puppy/agents/pack/terrier.py`
- `source/code_puppy-main/code_puppy/agents/pack/shepherd.py`
- `source/code_puppy-main/code_puppy/agents/pack/watchdog.py`
- `source/code_puppy-main/code_puppy/agents/pack/retriever.py`

Automated AST inventory found 25 concrete `BaseAgent` subclasses in the agent and
pack directories. The 24 discoverable built-in Python agent names appear in the
source-agent matrix below; `JSONAgent` is mapped separately in the
registry/custom-agent parity section because `agent_manager.py` treats JSON agents
as file-backed configs.

## Mapping rules

- **Profile** means a Tet profile descriptor: prompt/tool/model/task/schema/cache
  overlays applied by the Universal Agent Runtime.
- **Worker** means a bounded runtime process/task/service with lifecycle,
  cancellation, artifacts, and events. Workers may run under a profile, but the
  profile itself does not own side effects.
- **Deferred** means no current Tet implementation should claim parity yet. The
  row is still mapped to a target concept so future backlog work has a landing
  pad.
- Review, tester, and security rows must never get raw write/shell powers from a
  profile. They may request named verifiers through the normal gates.

## Registry and custom-agent parity

| Source path | Observed role/capability | Tet mapping | Profile vs worker decision | Required overlays/tools/schema/cache behavior | Gating/safety notes | Downstream BD(s) |
|---|---|---|---|---|---|---|
| `source/code_puppy-main/code_puppy/agents/agent_manager.py` | Dynamically discovers Python agent classes and pack subpackages while excluding `JSONAgent` from subclass registration, then separately discovers JSON agents as file-backed configs plus plugin-registered agents; stores per-agent message histories; persists terminal-session agent choice; clones/deletes JSON agents. | Existing Tet pieces: `Tet.ProfileRegistry` for data descriptors and `Tet.Runtime.State` for active profile refs/hot-swap. Planned importer/manager UX for custom profile files. Python subclass discovery is intentionally not carried forward. | **Existing foundation + planned profile-management UX.** No separate runtime subclass zoo. | Registry descriptors already have prompt/tool/model/task/schema/cache overlays; future manager should expose list/inspect/swap/import/clone operations and preserve session refs through `Tet.Runtime.State`. Cache policy follows swap request: preserve/drop/replace. | Profile swaps must happen at safe turn boundaries or queue/reject. Cloning/importing custom profiles is config mutation and needs normal approval/audit once write tools exist. Plugin code must not smuggle executable behavior into a profile. | BD-0016, BD-0017, BD-0018; profile authoring UX deferred to BD-0039+ or later. |
| `source/code_puppy-main/code_puppy/agents/json_agent.py` | Concrete `BaseAgent` subclass `JSONAgent` that loads user/project JSON agent files; validates `name`, `description`, `system_prompt`, `tools`; optional `display_name`, `user_prompt`, `tools_config`, and `model`; filters tools against built-ins/UC registry; project agents override user agents. | Tet custom profile descriptor registry. Code Puppy JSON agents become Tet profile JSON after schema translation into overlays. | **Existing baseline profile schema; planned importer/compat layer.** This accounts for the AST-inventory `JSONAgent` row outside the 24 built-in Python source-agent matrix. | Translate `system_prompt` to prompt overlay, `tools` to tool allowlist, `model` to model overlay/profile pin, optional user prompt to prompt layer metadata, and tool config to tool overlay metadata. Structured-output custom profiles should declare schema overlays. Cache defaults to preserve for prompt-only custom agents; drop when tool/model compatibility changes. | Tet must validate descriptors before runtime use. Unknown tools fail closed; UC tools do not auto-register. Project/user precedence should be explicit and audited, not path magic. | BD-0017, BD-0039, BD-0040. |

## Source agent parity matrix

| Code Puppy agent | Source path | Observed role/capability | Tet mapping | Decision/status | Required overlays/tools/schema/cache behavior | Gating/safety notes | Downstream BD(s) |
|---|---|---|---|---|---|---|---|
| `code-puppy` | `source/code_puppy-main/code_puppy/agents/agent_code_puppy.py` | Default coding agent with read/search, file create/replace/delete, shell, ask-user, subagent, skill, and image tools. | `coder` base profile, with `tool_use` as today's closest bundled fallback. | **Planned profile.** | Prompt overlay should preserve Tet coding style and file-size/DRY/YAGNI/SOLID rules; tool overlay allows read tools, patch preview/apply only through approval, named shell/verifier runner, ask-user, skill/profile helpers, and image attachments when available; schema returns action summary, files changed, tests, risks; cache preserve unless tool/model overlay changes. | Mutating file and shell tools require active acting task, path policy, approval where needed, artifacts, and verifier events. No raw bypass around patch/shell gates. | BD-0039; depends on BD-0028, BD-0029, BD-0030. |
| `planning-agent` | `source/code_puppy-main/code_puppy/agents/agent_planning.py` | Strategic planner that explores code, reads config/docs, decomposes work, asks questions, recommends agents, and outputs phased plans. | `planner` profile. | **Planned profile.** | Prompt overlay for project analysis, requirement breakdown, risk assessment, and handoff format; tool overlay read-only (`list`, `read`, `search`, `repo-scan`, `ask-user`) plus future agent-list/invoke when bounded workers exist; schema should validate objective, phases, tasks, risks, assumptions; cache preserve. | Plan mode cannot mutate files or execute arbitrary shell. External research/MCP later needs trust and network gates. | BD-0025, BD-0039, BD-0044. |
| `prompt-reviewer` | `source/code_puppy-main/code_puppy/agents/prompt_reviewer.py` | Reviews prompts for clarity, specificity, context, constraints, ambiguity, and actionability; can inspect project files and run shell in source. | `prompt_reviewer` profile backed by Prompt Lab concepts. | **Planned profile; partly adjacent to existing `Tet.PromptLab` advisory runtime.** | Prompt overlay for 5-dimension assessment; tools should be read-only plus prompt-lab refinement APIs, not raw shell by default; schema should validate scores, findings, improved prompt, and next steps; cache preserve. | Prompt review may guide but cannot widen deterministic gates. Shell use from Code Puppy should become named validators only if needed. | BD-0039, BD-0040, BD-0047. |
| `code-reviewer` | `source/code_puppy-main/code_puppy/agents/agent_code_reviewer.py` | General holistic reviewer for correctness, security, performance, maintainability, tests, docs; collaborates with specialists. | `reviewer` profile. | **Planned profile.** | Prompt overlay for findings ordered by severity and final verdict; tool overlay read/search/git-diff plus named verifier/SAST/test commands via policy, optional bounded specialist invoke; schema `findings[]`, `verdict`, `commands`, `residual_risk`; cache preserve prompt, drop tool cache if diff/tool manifest changes. | Reviewer cannot write or approve its own bypass. Verifier execution must be named allowlist, artifacted, and gate-checked. | BD-0039, BD-0040; shell policy BD-0029. |
| `python-reviewer` | `source/code_puppy-main/code_puppy/agents/agent_python_reviewer.py` | Python pull-request reviewer for PEP 8/20, typing, async, packaging, testing, security, and idioms. | `reviewer.python` specialization over `reviewer`. | **Planned profile specialization.** | Prompt layer narrows file scope to Python and pyproject/tooling changes; tool allowlist same as reviewer with Python verifier names (`ruff`, `mypy`, `pytest`, `bandit`, dependency audit) when configured; structured findings include language tag; cache preserve. | Same reviewer gates; no direct writes; security findings may request `security` profile handoff. | BD-0039, BD-0040, BD-0029. |
| `javascript-reviewer` | `source/code_puppy-main/code_puppy/agents/agent_javascript_reviewer.py` | JavaScript reviewer for ES/Node/browser async, bundle, performance, security, and tooling. | `reviewer.javascript` specialization. | **Planned profile specialization.** | Read/search/git-diff plus named JS verifiers (`eslint`, `vitest`/`jest`, bundle/security checks) when allowlisted; schema same as reviewer with JS runtime/build fields; cache preserve. | No npm install or arbitrary package mutation from reviewer. Dependency scans are verifier events. | BD-0039, BD-0040, BD-0029. |
| `typescript-reviewer` | `source/code_puppy-main/code_puppy/agents/agent_typescript_reviewer.py` | TypeScript reviewer for strict typing, runtime validation, framework idioms, DX, and build impact. | `reviewer.typescript` specialization. | **Planned profile specialization.** | Tool overlay reviewer baseline plus named TypeScript verifiers (`tsc --noEmit`, ESLint, tests) through policy; schema captures type-safety findings and verdict; cache preserve. | Type review cannot change configs; config remediation goes to coder under acting task. | BD-0039, BD-0040, BD-0029. |
| `golang-reviewer` | `source/code_puppy-main/code_puppy/agents/agent_golang_reviewer.py` | Go reviewer focused on idioms, concurrency, gofmt/go vet/staticcheck, tests, race, modules. | `reviewer.go` specialization. | **Planned profile specialization.** | Reviewer prompt layer for Go-only scope; named Go verifiers (`go test`, `go test -race`, `go vet`, staticcheck) when allowlisted; schema same reviewer envelope; cache preserve. | Shell/verifier runner must scrub env and artifact stdout/stderr. | BD-0039, BD-0040, BD-0029. |
| `c-reviewer` | `source/code_puppy-main/code_puppy/agents/agent_c_reviewer.py` | C systems reviewer for memory lifetime, UB, concurrency/interrupt safety, perf, fuzzing, sanitizers. | `reviewer.c` specialization. | **Planned profile specialization.** | Reviewer baseline plus C build/sanitizer/static-analysis verifier names; schema includes memory-safety/perf/security categories; cache preserve. | Review cannot execute arbitrary binaries; build/test commands require sandboxed verifier policy. | BD-0039, BD-0040, BD-0029. |
| `cpp-reviewer` | `source/code_puppy-main/code_puppy/agents/agent_cpp_reviewer.py` | C++ reviewer for modern C++, RAII, UB, ABI, concurrency, performance, build tooling. | `reviewer.cpp` specialization. | **Planned profile specialization.** | Reviewer baseline plus C++ build/test/sanitizer/static-analysis verifier names; schema same reviewer envelope with C++ categories; cache preserve. | Same reviewer verifier gates; no dependency/toolchain mutation. | BD-0039, BD-0040, BD-0029. |
| `python-programmer` | `source/code_puppy-main/code_puppy/agents/agent_python_programmer.py` | Python-focused coding agent with full file mutation, shell, subagent, and skills; emphasizes modern Python, typing, async, tests, package/security workflow. | `coder.python` profile specialization over `coder`. | **Planned profile specialization.** | Prompt overlay narrows coding guidance to Python; tools same gated coder set; model pin may prefer tool-capable coding model; schema action summary/tests/files; cache preserve unless model/tool overlay changes. | Full mutating gates apply. Package/dependency changes need explicit approval and audit. | BD-0039; depends on BD-0028, BD-0029, BD-0030. |
| `qa-expert` | `source/code_puppy-main/code_puppy/agents/agent_qa_expert.py` | Risk-based QA strategist for coverage, automation, release readiness, metrics, performance, security, accessibility, CI gates. | `tester` / `qa` profile. | **Planned profile.** | Prompt overlay for QA strategy and release-readiness verdict; tools read/search/git-diff plus named test/perf/security verifiers, optional specialist invoke; schema `test_results`, `coverage_gaps`, `readiness_verdict`, `recommendations`; cache drop or replace around verifier runs to avoid stale results. | Tester cannot bypass verifier allowlists or mutate test code directly; remediation routes to coder profile. | BD-0039, BD-0040, BD-0029. |
| `qa-kitten` | `source/code_puppy-main/code_puppy/agents/agent_qa_kitten.py` | Playwright/browser automation QA with browser lifecycle, semantic locators, screenshots, visual analysis, saved workflows. | Future `browser_qa` profile plus `browser_worker`. | **Explicitly deferred worker.** Current Tet has no browser tool contracts or browser lifecycle. | Future profile needs browser prompt and structured workflow/test artifact schema; worker needs browser session lifecycle, screenshots as artifacts, network policy, secret redaction, and cache drop for live page state. | Browser automation is high-risk external execution/network/UI state. Must be bounded, cancellable, artifacted, and policy-gated; no hidden browser side door. | Deferred; likely after BD-0044/BD-0046 and future browser-tool BD. |
| `terminal-qa` | `source/code_puppy-main/code_puppy/agents/agent_terminal_qa.py` | Terminal/TUI QA using API server, terminal browser, command execution, screenshots, output reading, mockup comparison; must close terminal/browser. | Future `terminal_qa` profile plus `terminal_worker`. | **Explicitly deferred worker.** Current Tet has no terminal/TUI tool contracts. | Future profile needs terminal testing prompt and schema for command transcript, visual artifacts, verdict; worker needs API/server lifecycle, command sandbox, screenshot artifacts, mandatory cleanup; cache drop for live terminal state. | Command execution requires shell policy and sandbox; browser/terminal cleanup must be enforced by worker finalizers, not prompt vibes. | Deferred; depends on BD-0029 and future terminal-worker BD. |
| `security-auditor` | `source/code_puppy-main/code_puppy/agents/agent_security_auditor.py` | Risk-based security auditor for controls, findings severity, compliance, SAST/DAST/SCA/container/IaC scans, remediation. | `security` profile. | **Planned profile.** | Prompt overlay for standards, evidence, risk scoring, remediation roadmap; tools read/search/git-diff plus named SAST/SCA/secret scan/verifier commands; schema `security_findings[]`, severity, evidence, affected assets, remediation, residual risk; cache drop around scanner output. | Security profile is read/verifier-only. It cannot approve or run arbitrary exploit tools outside policy. Findings route through Event Log/artifacts. | BD-0039, BD-0040, BD-0029. |
| `agent-creator` | `source/code_puppy-main/code_puppy/agents/agent_creator_agent.py` | Guides creation of JSON agent configs, lists available tools/models/UC tools, validates schema, writes user agent JSON. | `profile_author` profile over Tet profile registry/importer. | **Planned/deferred UX profile.** Validation foundation exists, write UX does not. | Prompt overlay should teach Tet profile schema, not Code Puppy JSON; tools read-only plus registry inspect/validate, and approved patch/config write for profile files; schema outputs proposed descriptor and validation errors; cache preserve. | Creating/updating profile files mutates config and can widen capabilities; require approval, validation, and audit before activation. UC tool exposure must fail closed. | BD-0017 foundation; profile authoring deferred to BD-0039+ or later. |
| `helios` | `source/code_puppy-main/code_puppy/agents/agent_helios.py` | Universal Constructor that writes persistent Python custom tools and can call/list/update them. | Future `tool_author` concept, not a Phase 11 profile. | **Explicitly deferred / not carried forward as-is.** | If ever added, descriptor would need a restricted authoring prompt, signed/validated tool manifests, schema for tool proposal/review, and cache drop on tool catalog changes. | Dynamic executable tool creation is a policy/security boundary, not a profile trick. No runtime code generation should bypass ADR-0005 gates, review, tests, approvals, or provenance. | Deferred; maybe future extension/MCP/tool-author work after BD-0041/BD-0043. |
| `scheduler-agent` | `source/code_puppy-main/code_puppy/agents/agent_scheduler.py` | Creates/manages scheduled Code Puppy tasks, daemon status/start/stop, task logs, immediate runs. | Future `scheduler_worker` plus optional scheduler-management profile. | **Explicitly deferred worker.** | Future profile needs schedule-management schema; worker needs durable schedule store, daemon supervision, run history/artifacts, and profile/task refs; cache not relevant for daemon state except preserving profile pins per scheduled run. | Scheduler can trigger future actions without an interactive human in-loop; must require explicit policy, approvals for risky actions, audit logs, and bounded runtime. | Deferred; no Phase 11 BD identified. |
| `pack-leader` | `source/code_puppy-main/code_puppy/agents/agent_pack_leader.py` | Orchestrates local pack workflow: declare base branch, create/query `bd` issues, create worktrees, invoke coder, require Shepherd/Watchdog, merge with Retriever, close issues. | `pack_coordinator` profile plus future workflow coordinator/worker supervisor. | **Planned profile overlay; bounded worker orchestration deferred to Phase 13.** | Prompt overlay for workflow planning and critic pattern; tool overlay read/search plus task/worktree/review/merge worker APIs when implemented, not raw shell; schema workflow plan, issue graph, worker assignments, approvals, merge status; cache replace at worker-boundary summaries. | Out of scope: unbounded parallelism and remote pools. Coordinator cannot bypass task gates, reviewer/tester gates, approvals, or merge policy. | BD-0039 for profile; BD-0044–BD-0046 for workers/fan-out. |
| `bloodhound` | `source/code_puppy-main/code_puppy/agents/pack/bloodhound.py` | Pack issue-tracking specialist for local `bd` commands, dependency trees, ready/blocked queries, comments, close/reopen. | Future `task_tracker` adapter/worker, probably mapping to Tet TaskManager rather than direct `bd`. | **Explicitly deferred worker/adapter.** | Future adapter needs task/dependency schemas, ready/blocked output, comments/events, and no direct `.beads` coupling in core. Cache preserve task graph refs with event invalidation on changes. | Issue tracker writes mutate project/task state; require task-store gates and audit. This research change must not touch `.beads`. | BD-0023 TaskManager; BD-0044 worker integration later. |
| `terrier` | `source/code_puppy-main/code_puppy/agents/pack/terrier.py` | Git worktree specialist: create/list/remove/prune worktrees and branches for parallel development. | Future `worktree_worker`. | **Explicitly deferred worker.** | Worker needs git worktree operations as named actions, branch/path schema, cleanup/lease state, artifacts/logs, and cache drop/revalidate workspace refs after mutations. | Worktree creation/removal mutates filesystem/git state; requires active task, base branch policy, path containment, approval where configured, and cleanup events. | BD-0029 shell/git policy; BD-0044–BD-0046 bounded workers. |
| `shepherd` | `source/code_puppy-main/code_puppy/agents/pack/shepherd.py` | Pack code-review critic that reviews worktree changes, runs linters/tests, returns `APPROVE` or `CHANGES_REQUESTED`. | `critic.review` or `reviewer` profile used as a bounded review worker in pack workflows. | **Planned profile.** | Prompt overlay for pack critic verdict; tools read/search/git-diff plus named verifiers only; schema verdict, must-fix/should-fix/consider, commands, evidence; cache drop around diff/verifier artifacts. | Critic cannot merge, write fixes, or bypass tool gates. Approval by profile is advisory; runtime merge gate remains deterministic. | BD-0039, BD-0040; worker use BD-0044. |
| `watchdog` | `source/code_puppy-main/code_puppy/agents/pack/watchdog.py` | Pack QA critic that finds/runs tests, checks coverage/edge cases, returns approve/request changes. | `critic.test` or `tester` profile used as bounded QA worker. | **Planned profile.** | Prompt overlay for pack QA verdict; tools read/search/git-diff plus named test/coverage verifiers; schema test result summary, coverage gaps, verdict, recommendations; cache drop around test outputs. | Tester cannot modify tests or merge. Test commands require verifier allowlist and artifacted stdout/stderr. | BD-0039, BD-0040; worker use BD-0044. |
| `retriever` | `source/code_puppy-main/code_puppy/agents/pack/retriever.py` | Local branch merge specialist: fetch, checkout base, merge feature branch, handle/abort conflicts, branch cleanup, notify pack. | `merge_worker` / `retriever` worker with optional `merge_operator` profile. | **Explicitly deferred worker.** | Worker needs named git fetch/merge/abort/status/cleanup actions, branch/base schema, conflict artifact schema, merge result events, cache/workspace invalidation after merge. | Git merge and branch deletion are mutating. Must require clean worktree preflight, approvals/policy, conflict escalation, artifacted logs, and no forceful history rewrite by prompt. | BD-0029, BD-0034/BD-0035 for durable events/replay, BD-0044–BD-0046. |

## Pack and adjacent specialty gaps

- `source/code_puppy-main/code_puppy/agents/pack/__init__.py` confirms the pack
  set as Bloodhound, Terrier, Code-Puppy, Shepherd, Watchdog, and Retriever under
  Pack Leader coordination. The six named pack roles are all mapped above.
- No `packager` or `packager.py` source agent was found under
  `source/code_puppy-main/code_puppy/agents`. The packaging/retrieval concept in
  the Phase 11 wording maps to Pack Leader/Retriever/Merge Worker for now; a
  release-packaging worker is explicitly **not implemented and not sourced** in
  this matrix.
- No dedicated Code Puppy repair agent was found under the inspected agents
  directory. Tet still needs a `repair` profile/workflow from ADR-0008, but that
  is a Tet-planned capability rather than Code Puppy source parity. It remains
  **deferred** until repair backlog work.

## Normalized target profile/worker set

Planned core profiles for BD-0039:

- `planner`
- `coder`
- `coder.python`
- `reviewer`
- `reviewer.python`
- `reviewer.javascript`
- `reviewer.typescript`
- `reviewer.go`
- `reviewer.c`
- `reviewer.cpp`
- `prompt_reviewer`
- `tester`
- `security`
- `profile_author`
- `critic.review`
- `critic.test`
- `pack_coordinator`

`json_data` is only shorthand in this document for the custom JSON-agent
compatibility/importer data path described above; it is **not** a committed Tet
profile ID for BD-0039 unless a later schema/design BD explicitly accepts it.

Deferred/planned workers or adapters:

- `task_tracker` adapter/worker for Bloodhound-style issue operations
- `worktree_worker` for Terrier-style git worktree operations
- `merge_worker` for Retriever-style merge operations
- `browser_worker` for QA Kitten-style browser automation
- `terminal_worker` for Terminal QA-style TUI testing
- `scheduler_worker` for scheduled task/daemon management
- `tool_author` extension workflow for Helios-like dynamic tools, if ever accepted
- `repair_worker` / `repair` workflow from ADR-0008, with no direct Code Puppy
  source agent equivalent

## Verification checklist

- [x] `agent_manager.py` mapped to Tet profile registry + runtime state hot-swap.
- [x] `json_agent.py` / `JSONAgent` mapped to Tet profile descriptor/importer
  path, separate from built-in Python class discovery.
- [x] AST inventory found 25 concrete Code Puppy `BaseAgent` subclasses total,
  including `JSONAgent`; the 24 discoverable built-in Python agent names that
  `agent_manager.py` registers as classes are present in the source-agent matrix:
  `code-puppy`, `planning-agent`, `prompt-reviewer`, `code-reviewer`,
  `python-reviewer`, `javascript-reviewer`, `typescript-reviewer`,
  `golang-reviewer`, `c-reviewer`, `cpp-reviewer`, `python-programmer`,
  `qa-expert`, `qa-kitten`, `terminal-qa`, `security-auditor`,
  `agent-creator`, `helios`, `scheduler-agent`, `pack-leader`, `bloodhound`,
  `terrier`, `shepherd`, `watchdog`, and `retriever`.
- [x] Every inspected pack role listed in `pack/__init__.py` is mapped.
- [x] Browser QA, terminal QA, scheduler, dynamic tool construction, issue
  tracker, worktree, and merge roles are explicitly deferred as workers where Tet
  lacks current runtime/tool contracts.
- [x] Reviewer/tester/security rows require named verifier/tool gates and do not
  grant write or raw shell bypasses.
- [x] Structured-output needs are captured for reviewer/tester/security/custom
  JSON-agent compatibility rows and routed to BD-0040.
- [x] Current Tet registry reality is documented: only `tet_standalone`, `chat`,
  and `tool_use` exist today.

## Verification commands used for this research

The source inventory was checked with an AST script over
`source/code_puppy-main/code_puppy/agents` in the sibling checkout
`../tet/source/code_puppy-main`, because this isolated worktree does not contain
`source/`. The literal concrete-subclass scan confirmed `COUNT 25`; excluding
`JSONAgent` gives `NON_JSON_COUNT 24`, which matches the 24 source-agent matrix
rows.

The source/name coverage check parsed the non-JSON `BaseAgent` subclasses' literal
`name` properties and matched every `| name | path |` row in this document. It
returned `SOURCE_NAME_COUNT 24`, `MISSING_MATRIX_ROWS 0`, `MISSING_PATHS 0`,
`JSON_AGENT_PATH_PRESENT True`, and `JSON_AGENT_TEXT_PRESENT True`. Follow-up
verification should grep this document for every source path above and run the
standard Elixir checks.
