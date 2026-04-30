# BD-0009 — Web removability acceptance gate

Status: Accepted local gate
Date: 2026-04-30
Issue: `tet-db6.9` / `BD-0009`

## Purpose

This gate proves the standalone Tet product can compile, test, and assemble its
release after the optional web adapter is removed or absent.

It deliberately does **not** add Phoenix, LiveView, Plug, Cowboy, Bandit, a web
endpoint, a router, a generated Phoenix application, or web-owned storage. The
point is removability, not smuggling in a browser-shaped dependency burrito.

BD-0007 defines the future optional `tet_web_phoenix` facade contract. BD-0009
turns that contract into a local CI-like check: if a future web adapter leaks
into CLI/runtime/core/store, deleting that adapter must break this gate before it
breaks a release.

## Command

Run the full local removability gate from the repository root:

```bash
tools/check_web_removability.sh
# or
mix web.removability
```

For debugging, keep the disposable sandboxes:

```bash
TET_REMOVABILITY_KEEP_SANDBOX=1 tools/check_web_removability.sh
```

For rare local iteration when you only want the positive gate and not the cheap
negative smoke:

```bash
tools/check_web_removability.sh --skip-negative-smoke
```

CI should use the default command, including the negative smoke.

## What the gate does

`tools/check_web_removability.sh` performs these steps:

1. Runs `tools/check_web_facade_contract.sh` in the current working tree. This
   catches direct non-web umbrella app dependencies on Phoenix, Plug, Cowboy,
   LiveView, websocket server packages, or `tet_web*` apps. If a future
   `apps/tet_web_phoenix` exists, it also applies the BD-0007 facade/source
   contract.
2. Creates a temporary copy of the working tree with `.git`, `.beads`, `_build`,
   `deps`, editor/cache directories, and crash/build noise excluded.
3. Injects a temporary fake non-web app with `{:phoenix, "~> 1.7"}` in that
   copy and verifies the facade/dependency guard fails. This is the negative
   smoke proving the guard bites a representative web leak.
4. Creates a fresh temporary copy of the working tree, again excluding `.git`,
   `.beads`, `_build`, and `deps`.
5. Deletes optional web adapter directories from the sandbox:
   - `apps/tet_web`
   - `apps/tet_web_*`, including the planned `apps/tet_web_phoenix`
6. Runs:

   ```bash
   MIX_ENV=test mix compile --warnings-as-errors
   MIX_ENV=test mix standalone.check
   ```

   `mix standalone.check` already runs formatting, the web facade contract,
   ExUnit, and `tools/check_release_closure.sh`.
7. Performs one final release-lib name scan to ensure the sandboxed
   `tet_standalone` release does not contain forbidden web libraries.

The gate uses a sandbox so it can prove deletion/removal without mutating the
working tree. Very polite. Still opinionated. Like a tiny CI butler with teeth.

## What this proves

Passing the gate means:

- standalone source compiles with warnings treated as errors after web adapter
  directories are removed;
- the test suite passes in the same web-removed sandbox;
- `tet_standalone` assembles in the web-removed sandbox;
- the assembled release closure excludes known web framework/server apps:
  Phoenix, LiveView, Plug, Cowboy, Bandit, Ranch, Thousand Island, WebSock, and
  `tet_web*` apps;
- non-web umbrella app `mix.exs` files do not directly depend on web stack apps;
- the BD-0007 optional-web facade contract remains executable even when no web
  app exists;
- `.beads` and Git metadata are not needed for the standalone build/test/release
  path.

## Failure classes caught

The gate is intended to fail when any of these happen:

- `tet_core`, `tet_runtime`, `tet_cli`, `tet_store_*`, or other non-web apps add
  a dependency such as `{:phoenix, ...}`, `{:plug_cowboy, ...}`, `{:bandit, ...}`,
  or `{:tet_web_phoenix, ...}`;
- a non-web app starts relying on modules or compile-time files that only exist
  under `apps/tet_web*`;
- root release configuration accidentally includes `tet_web*` or web framework
  applications in `tet_standalone`;
- tests only pass when the optional web app is present;
- release assembly or release metadata pulls Phoenix/Plug/Cowboy/LiveView or
  websocket server libraries into the standalone closure;
- a future web app violates the BD-0007 facade-only contract.

## Relationship to existing guards

BD-0009 builds on the existing standalone guard stack instead of replacing it:

| Guard | Role in BD-0009 |
|---|---|
| `tools/check_web_facade_contract.sh` | Source/dependency contract for optional web and non-web apps. Runs in the working tree and sandbox. |
| `tools/check_release_closure.sh` | Builds/inspects `tet_standalone` and rejects forbidden web apps in release libs/metadata. Called by `mix standalone.check`. |
| `mix standalone.check` | Existing local boundary alias: format, facade contract, tests, release closure. Runs inside the web-removed sandbox. |
| `mix web.removability` | Mix wrapper for `tools/check_web_removability.sh`. |

This layering is intentionally boring. Boring verification is excellent. Novel
verification is how you end up debugging your debugger at 1 a.m.

## Future optional web adapter expectations

When `apps/tet_web_phoenix` eventually exists, it must remain optional:

```text
tet_web_phoenix -> tet_runtime -> tet_core
                -> tet_core for renderable data contracts
```

The forbidden direction stays forbidden:

```text
tet_core/tet_runtime/tet_cli/tet_store_* -> tet_web_phoenix | Phoenix | Plug | Cowboy | LiveView
```

The removability gate should still pass after physically deleting
`apps/tet_web_phoenix` from the sandbox. If it does not, the web adapter has
become part of the standalone product by accident. That is not optional; that is
architecture glitter in the gears.

## Recommended local verification set

For this repository state, run:

```bash
mix format --check-formatted
mix test
tools/check_web_removability.sh
mix standalone.check
git diff --name-only HEAD -- . ':!*.md'
git status --short -- .beads
git diff --name-only HEAD | grep '^\\.beads/' && exit 1 || true
```

The final `.beads` checks are not part of the Mix alias because issue-tracker
files are intentionally outside the build. Keep them out of commits.

## Limits

This gate cannot prove behavior for a web release that does not exist yet, and
it does not compile Phoenix when Phoenix is absent. That is by design. The gate
proves the standalone path does not need the optional web adapter.

When a real `tet_web_phoenix` app lands, a separate web release/adapter CI job
should compile and test the web app itself. BD-0009 remains the acceptance gate
for the opposite property: removing that web app must leave standalone Tet
healthy.
