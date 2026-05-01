# 05 — Tools, Policy, Approvals, and Verification

## Tool principle

Every tool intent goes through policy before execution. There is no direct path to file writes, command execution, or patch application.

```text
provider/tool intent
  -> Tet.Policy.check_tool/1
  -> allow: execute tool, persist tool_run, emit events
  -> pending approval: save diff artifact + pending approval, emit events
  -> block: persist blocked tool_run, emit tool.blocked
```

## V1 tool surface

Read tools:

```text
list_dir(path)
read_file(path)
search_text(query, path)
git_status()
git_diff()
```

Write tools:

```text
propose_patch(diff)
apply_approved_patch(approval_id)
```

Verifier tool:

```text
run_command(verifier_name)
```

No arbitrary shell strings. No direct file write tool. No network tools.

## Tool behaviour

```elixir
defmodule Tet.Tool do
  @callback name() :: binary()
  @callback read_or_write() :: :read | :write
  @callback run(args :: map(), context :: map()) :: {:ok, map()} | {:error, term()}
end
```

Concrete tool modules live in `tet_runtime`, for example:

```text
Tet.Tools.LocalFs.ListDir
Tet.Tools.LocalFs.ReadFile
Tet.Tools.Search.SearchText
Tet.Tools.Git.Status
Tet.Tools.Git.Diff
Tet.Tools.Patch.ProposePatch
Tet.Tools.Patch.ApplyApprovedPatch
Tet.Tools.Verifier.RunCommand
```

## Per-tool rules

### `list_dir(path)`

- canonicalize path;
- reject if outside workspace root;
- hide `.tet/` internals by default;
- cap entry count;
- return name/type/size triples.

### `read_file(path)`

- canonicalize path;
- reject escapes;
- cap read size, default 256 KB;
- binary files return a summary, not bytes;
- redact before display.

### `search_text(query, path)`

- canonicalize path;
- reject escapes;
- cap result count and total bytes;
- ignore `.git`, `node_modules`, `_build`, `deps`, `target`, `.tet` by default.

### `git_status()` / `git_diff()`

- run only with `cd: workspace.root_path`;
- not generic git passthrough;
- `git_diff` has diff-size cap.

### `propose_patch(diff)`

Does not modify disk.

Steps:

1. validate unified-diff format;
2. reject paths outside workspace root;
3. reject patch over `max_patch_bytes`;
4. create `Tet.Artifact{kind: :diff}`;
5. create `Tet.ToolRun{status: :waiting_approval}`;
6. create `Tet.Approval{status: :pending}`;
7. emit `tool.requested`, `artifact.created`, `approval.created`;
8. return approval id.

### `apply_approved_patch(approval_id)`

Modifies disk only when all are true:

- approval exists and status is approved;
- approval belongs to current session/workspace;
- approval has valid diff artifact;
- workspace is trusted;
- session mode is execute;
- active task exists;
- patch still applies cleanly.

Steps:

1. snapshot changed files when practical;
2. apply patch using an internal unified-diff applier or safe library, not shelling to arbitrary commands;
3. update tool run status;
4. emit `patch.applied` or `patch.failed`;
5. optionally run configured verifier.

### `run_command(verifier_name)`

- resolve name from `[verification.allowlist]`;
- never accept raw shell strings;
- use `System.cmd(program, args, cd: workspace.root_path, env: scrubbed_env)`;
- enforce timeout;
- save stdout/stderr artifacts;
- redact before display;
- emit verifier events.

## Policy API

```elixir
@type tool_check :: %{
  session: Tet.Session.t(),
  workspace: Tet.Workspace.t(),
  task: Tet.Task.t() | nil,
  tool_name: binary(),
  read_or_write: :read | :write,
  args: map()
}

@spec Tet.Policy.check_tool(tool_check()) ::
  {:allow, normalized_args :: map()}
  | {:require_approval, normalized_args :: map()}
  | {:block, reason :: atom()}
```

Policy reason atoms:

```text
:path_outside_workspace
:path_symlink_escape
:path_missing
:tool_not_in_mode
:workspace_untrusted
:no_active_task
:another_pending_approval
:patch_too_large
:command_not_in_allowlist
:file_too_large
:invalid_patch
:verifier_timeout
```

## Mode policy matrix

| Tool | Chat | Explore | Execute |
|---|:---:|:---:|:---:|
| `list_dir` | block | allow | allow |
| `read_file` | block | allow | allow |
| `search_text` | block | allow | allow |
| `git_status` | block | allow | allow |
| `git_diff` | block | allow | allow |
| `propose_patch` | block | block | allow → pending approval |
| `apply_approved_patch` | block | block | allow only after approval |
| `run_command` | block | block | allowlisted only |

Any allow cell still passes path/trust/task/size checks.

## Path policy

Required shape:

```elixir
allowed_path?(workspace_root, requested_path) ::
  {:ok, canonical_path}
  | {:error, :outside_workspace}
  | {:error, :symlink_escape}
  | {:error, :missing}
```

Algorithm:

1. expand `~`, env vars, `.`, `..`;
2. expand relative paths against workspace/current command context;
3. inspect each ancestor for symlinks;
4. resolve symlinks and re-check final path inside workspace;
5. compare canonical prefixes using OS-aware case rules;
6. block `.tet/` internals unless explicitly allowed by tool/config.

Adversarial cases that must be blocked:

```text
../outside.txt
/tmp/secret.txt
repo/subdir/../../outside.txt
symlink-to-outside/file.txt
/proc/self/environ
```

## Approval lifecycle

```text
propose_patch
    │
    ▼
pending ───────► rejected  (terminal)
    │
    ▼
approved
    │
    ▼
apply_approved_patch
    │
    ├─ success ─► verified | verifier_failed
    └─ failed  ─► error
```

Only these statuses live on approval rows:

```text
pending
approved
rejected
```

Patch application is a tool-run result and event, not an approval status.

## Redaction

Redact before display in CLI, LiveView, logs, and errors.

Patterns:

- API key shapes;
- bearer tokens;
- private key blocks;
- `.env`-style secret keys;
- `Authorization` headers;
- database URLs with passwords.

Pure API:

```elixir
Tet.Redactor.redact(text) :: %{redacted: text, patterns: [atom()]}
```

Store redaction metadata in artifact/event metadata when useful.

## Explicitly not allowed in v1

- arbitrary shell execution;
- direct file writes;
- delete-file tool;
- network tools;
- package installation tools;
- remote execution;
- credential access;
- editing outside workspace root;
- background patch application without user approval;
- parallel write tools in the same session.
