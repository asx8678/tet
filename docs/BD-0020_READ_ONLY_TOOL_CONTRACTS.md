# BD-0020 — Read-only tool contracts

Status: Implemented as pure core contracts
Issue: `BD-0020: Read-only tool contracts`
Phase: Phase 6 — Read-only tool layer

## Purpose

BD-0020 defines the typed manifest/schema layer for the first native read-only
Tet tools:

- `list`
- `read`
- `search`
- `repo-scan`
- `git-diff`
- `ask-user`

These are **contracts only**. They do not execute filesystem reads, git calls,
terminal prompts, policy checks, event writes, or redaction passes by themselves.
The contract catalog lives in `tet_core` so runtime, CLI, future web adapters,
and later executor layers all see one boring, deterministic truth instead of six
slightly different maps wearing fake moustaches.

Plan anchors:

- §13 Tooling and MCP: every tool is a manifest plus executor; manifests declare
  schemas, read/write/execute classification, modes, task categories, path
  policy posture, timeout, output caps, redaction class, source, and approval
  requirements.
- §21 Security and sandboxing: filesystem access must be path-contained,
  bounded, redacted before exposure, and policy-enforced outside prompts.
- Phase 6 / BD-0020: define typed contracts for list/read/search/repo-scan/
  git-diff/ask-user with limits, redaction, task correlation, and error shapes.

Source parity references used for shape only:

- `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/__init__.py`
- `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/file_operations.py`
- `/Users/adam2/projects/tet/source/code_puppy-main/code_puppy/tools/ask_user_question/handler.py`

## Public core surface

The public pure facade is:

```elixir
Tet.Tool.read_only_contracts()
Tet.Tool.read_only_contract_names()
Tet.Tool.fetch_read_only_contract(name_or_alias)
```

The implementation modules are:

- `Tet.Tool.Contract` — typed contract struct, validation, JSON-friendly
  conversion.
- `Tet.Tool.ReadOnlyContracts` — static native read-only catalog.
- `Tet.Tool.Schema` — internal JSON-schema-like helper builders.

`Tet.Core.boundary/0` advertises `:tool_contracts` as a core-owned capability.
No runtime app, store adapter, CLI renderer, Phoenix module, shell process, or
filesystem operation is introduced by BD-0020.

## Contract shape

Every read-only contract has these top-level fields:

| Field | Meaning |
|---|---|
| `name` | Stable canonical tool name. |
| `aliases` | Legacy/compatibility lookup names, e.g. `grep` for `search`. |
| `namespace` | Currently `native.read_only`. |
| `version` | Contract schema version, currently `1.0.0`. |
| `title` / `description` | Operator/provider-facing documentation. |
| `read_only` | Always `true`. |
| `interactive` | `true` only for `ask-user`; all others are non-interactive. |
| `mutation` | Always `:none`. |
| `approval` | Explicitly `required: false`; future policy may still block. |
| `modes` | Allowed runtime modes; `:chat` is intentionally absent. |
| `task_categories` | Task categories eligible to use the contract before narrower policy. |
| `input_schema` | JSON-schema-like argument shape for model/runtime requests. |
| `output_schema` | JSON-schema-like result envelope. |
| `error_schema` | Stable error envelope shared by all read-only tools. |
| `limits` | Uniform paths/results/bytes/timeouts categories. |
| `redaction` | Required redaction class and exposure sinks. |
| `correlation` | Runtime-supplied session/task/tool-call correlation metadata. |
| `execution` | Contract-only execution posture; no executor is enabled here. |
| `source` | Issue, phase, spec sections, and source-reference notes. |

`Tet.Tool.Contract.new/1` rejects missing top-level fields, unknown top-level
fields, mutating contracts, missing required correlation ids, and malformed
schema/limit/redaction/execution shapes with stable tagged errors. Unknown
catalog lookups return:

```elixir
{:error, {:unknown_read_only_tool_contract, "normalized-name"}}
```

## Catalog

| Name | Aliases | Interactive | Read-only posture | Key limits |
|---|---|---:|---|---|
| `list` | `list-files`, `list_files` | No | Lists bounded workspace entries only. | 5,000 paths/results, 200 KB output, 30 s. |
| `read` | `read-file`, `read_file` | No | Reads one bounded workspace text file/range. | 1 path, 1 MB read, 200 KB output, 30 s. |
| `search` | `grep`, `search-text` | No | Searches bounded text files and snippets. | 100 paths, 200 matches, 5 MB read cap, 30 s. |
| `repo-scan` | `repo_scan` | No | Summarizes repo shape without full file bodies. | 10,000 paths, 1,000 representative results, 45 s. |
| `git-diff` | `git_diff`, `diff` | No | Inspects bounded diff summary; no raw passthrough. | 500 paths/results, 5 MB diff read cap, 30 s. |
| `ask-user` | `ask_user`, `ask-user-question`, `ask_user_question` | Yes | Prompts operator; does not mutate workspace/store/shell. | 10 questions, 6 options/question, 32 KB output, 300 s. |

All six contracts set:

```elixir
read_only: true
mutation: :none
approval: %{required: false, ...}
execution: %{
  status: :contract_only,
  mutates_workspace: false,
  mutates_store: false,
  executes_code: false
}
```

`git-diff` records `effects: [:reads_git_index]`; `ask-user` records
`effects: [:operator_interaction]`. These effects are descriptive metadata for
future gates, not permission to execute anything in BD-0020.

## Input/output/error schemas

Each `input_schema`, `output_schema`, and `error_schema` is JSON-schema-like and
contains:

```text
type
properties
required
additional_properties
```

The output envelope is common across tools:

```text
ok
correlation
data
error
redactions
truncated
limit_usage
```

The error envelope is common across tools:

```text
code
message
kind
retryable
correlation
details
```

Common stable error codes include:

- `invalid_arguments`
- `workspace_escape`
- `path_denied`
- `not_found`
- `not_file`
- `not_directory`
- `permission_denied`
- `binary_file`
- `output_truncated`
- `timeout`
- `tool_unavailable`
- `git_unavailable`
- `not_git_repo`
- `non_interactive`
- `user_cancelled`
- `validation_failed`
- `internal_error`

`message` and `details` are contractually redacted before display, provider
context, log, event, or artifact exposure.

## Limits

Every contract has a uniform limit shape:

```elixir
%{
  paths: %{...},
  results: %{...},
  bytes: %{...},
  timeout_ms: positive_integer
}
```

The exact counters vary by tool, but the categories do not. This lets future
plan-mode gates and executor layers reason about path fanout, result fanout,
byte budgets, and timeout budgets without hand-parsing tool-specific folklore.

## Redaction

Every contract declares a redaction class and requires applying the central
redactor before these exposure sinks:

- provider context
- Event Log
- Artifact Store
- display / CLI / future UI
- logs

The catalog encodes the central redactor rule as:

```elixir
%{name: "central_redactor", module: "Tet.Redactor", function: "redact/1"}
```

BD-0020 does not perform redaction because it does not process tool data. Future
executor/event layers must apply this metadata before any output crosses a trust
boundary.

## Correlation

The runtime, not the model, supplies correlation metadata. Every contract
requires:

```text
session_id
task_id
tool_call_id
```

Optional fields are:

```text
turn_id
plan_id
request_id
```

The same correlation object appears in output and error envelopes so later Event
Log rows, CLI rendering, approvals, and plan-mode gates can tie a tool attempt
back to durable session/task context.

## Future plan-mode gates and execution layer

BD-0020 deliberately stops before execution. The next layers should consume the
contracts like this:

1. Fetch the contract by canonical name or alias.
2. Reject unknown contracts with the stable unknown-contract error.
3. Intersect mode/category/profile/policy permissions. Read-only contracts may
   be allowed in `:plan` and `:explore`, but no contract widens permissions by
   itself.
4. Attach runtime correlation metadata (`session_id`, `task_id`, `tool_call_id`).
5. Validate input against the contract schema.
6. Apply path policy, deny globs, symlink containment, and workspace bounds
   before any filesystem/git operation. This belongs to BD-0021.
7. Enforce limits for paths, results, bytes, and timeout.
8. Execute through a supervised runtime executor, never from `tet_core`.
9. Apply `Tet.Redactor.redact/1` and contract-specific redaction metadata before
   provider context, display, logs, Event Log, or artifacts.
10. Persist tool call/result/error events with correlation metadata. This belongs
    to BD-0022.

This keeps plan mode useful for research while preserving the no-mutation rule.
`ask-user` is interactive, but it is still non-mutating: it asks the operator for
clarification and future event capture may persist the answer, but the contract
itself does not modify workspace files, shell state, config, or store records.

## Boundary guarantees

BD-0020 preserves the standalone/no-web boundary:

- no Phoenix, LiveView, Plug, Cowboy, or web adapter dependency;
- no runtime process or supervisor added;
- no store adapter change;
- no shell/git/filesystem execution path;
- no Event Log writes yet;
- no `.beads` or issue-tracker file changes.

The contract catalog is safe to include in provider prompt assembly later,
provided callers use `Tet.Tool.Contract.to_map/1` or equivalent JSON-safe
conversion and still apply policy gates before dispatch. Contracts are maps, not
permission slips. Tiny but important distinction.
