# Final Acceptance Checklist

## Architecture

- [ ] `tet_core` has no Phoenix, Plug, Ecto, runtime, CLI, store-adapter, or web dependencies.
- [ ] `tet_runtime` has no Phoenix, Plug, LiveView, Phoenix.PubSub, `TetWeb`, or CLI dependencies.
- [ ] `tet_cli` has no Phoenix/Plug/web dependencies and calls only `Tet.*`.
- [ ] Store adapters depend only on `tet_core` plus their database libraries.
- [ ] Public `Tet` facade lives in `tet_runtime`, not `tet_core`.
- [ ] No root `Agent` namespace is used for the product.

## Standalone release

- [ ] `MIX_ENV=prod mix release tet_standalone` builds.
- [ ] Release lib directory contains no `phoenix*`, `plug*`, `cowboy*`, `phoenix_live_view*`, or `phoenix_pubsub*`.
- [ ] `Tet.Application` starts without `TetWeb.Endpoint`.
- [ ] Removing/excluding `tet_web_phoenix` does not break compile/test/release.

## CLI

- [ ] `tet doctor` works.
- [ ] `tet init . --trust` creates `.tet/` with DB/config/artifact dirs.
- [ ] `tet session new` creates chat/explore/execute sessions.
- [ ] `tet ask` persists messages and events.
- [ ] `tet explore` can read/search inside workspace.
- [ ] `tet edit` proposes a diff and exits 3 waiting for approval.
- [ ] `tet approvals` shows pending approvals.
- [ ] `tet patch approve` applies approved patch only.
- [ ] `tet patch reject` changes no files.
- [ ] `tet verify` runs only allowlisted commands.
- [ ] `tet status` shows latest state.
- [ ] Exit codes 0–9 are deterministic.

## Safety

- [ ] Chat mode blocks all tools.
- [ ] Explore mode blocks all writes and command execution.
- [ ] Execute mode blocks writes in untrusted workspaces.
- [ ] Path traversal and symlink escapes are blocked.
- [ ] `.tet/` internals are hidden by default.
- [ ] Patch apply without approved approval row is impossible.
- [ ] Oversized file reads and patches are blocked/truncated as configured.
- [ ] Blocked tool attempts are persisted.
- [ ] Redaction runs before display.

## Storage/events

- [ ] Memory and SQLite pass the same store contract tests.
- [ ] Events have stable per-session order.
- [ ] Artifacts save path/content/hash correctly.
- [ ] Re-opening a session restores timeline and approvals.

## Optional Phoenix

- [ ] Built only after CLI v1.
- [ ] LiveViews call `Tet.*` only.
- [ ] LiveViews render `%Tet.Event{}` and do not implement business rules.
- [ ] Phoenix can display CLI-created sessions.
- [ ] Phoenix approve/reject goes through `Tet.approve_patch/3` and `Tet.reject_patch/3`.
