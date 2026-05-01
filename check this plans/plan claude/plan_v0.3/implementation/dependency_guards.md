# Implementation — Dependency Guards

## `tools/check_imports.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="${ROOT:-.}"
status=0

fail() { echo "FAIL: $1"; status=1; }

if grep -RE 'Phoenix|Plug\.|TetWeb\.|Ecto\.|Tet\.Runtime' \
  --include='*.ex' --include='*.exs' \
  "$ROOT/apps/tet_core/lib" "$ROOT/apps/tet_core/test" 2>/dev/null; then
  fail "forbidden reference in tet_core"
fi

if grep -RE 'Phoenix|Plug\.|TetWeb\.|Tet\.CLI\.' \
  --include='*.ex' --include='*.exs' \
  "$ROOT/apps/tet_runtime/lib" "$ROOT/apps/tet_runtime/test" 2>/dev/null; then
  fail "forbidden reference in tet_runtime"
fi

if grep -RE 'Phoenix|Plug\.|TetWeb\.|Tet\.Store\.|Tet\.Runtime\.' \
  --include='*.ex' --include='*.exs' \
  "$ROOT/apps/tet_cli/lib" "$ROOT/apps/tet_cli/test" 2>/dev/null; then
  fail "forbidden reference in tet_cli"
fi

for app in tet_store_memory tet_store_sqlite tet_store_postgres; do
  dir="$ROOT/apps/$app"
  [ -d "$dir" ] || continue
  if grep -RE 'Phoenix|Plug\.|TetWeb\.|Tet\.CLI\.|Tet\.Runtime\.' \
    --include='*.ex' --include='*.exs' \
    "$dir/lib" "$dir/test" 2>/dev/null; then
    fail "forbidden reference in $app"
  fi
done

if grep -RE 'Phoenix\.PubSub' \
  --include='*.ex' --include='*.exs' \
  --exclude-dir='tet_web_phoenix' \
  "$ROOT/apps" 2>/dev/null; then
  fail "Phoenix.PubSub outside tet_web_phoenix"
fi

[ "$status" -eq 0 ] && echo "OK: source guard clean"
exit "$status"
```

## `tools/check_xref.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
mix xref graph --label compile-connected > /tmp/tet_xref.txt

violations=$(grep -E 'apps/tet_(core|runtime|cli).*->.*(Phoenix|Plug|TetWeb|phoenix|plug)' /tmp/tet_xref.txt || true)

if [ -n "$violations" ]; then
  echo "FAIL: forbidden xref edges:"
  echo "$violations"
  exit 1
fi

echo "OK: xref graph respects layering"
```

## `tools/check_release_closure.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
MIX_ENV=prod mix release tet_standalone --overwrite
REL_DIR="_build/prod/rel/tet_standalone/lib"

leaked=$(ls "$REL_DIR" | grep -E '^(phoenix|phoenix_live_view|phoenix_pubsub|plug|cowboy|phoenix_html)' || true)

if [ -n "$leaked" ]; then
  echo "FAIL: forbidden libraries in tet_standalone release closure:"
  echo "$leaked"
  exit 1
fi

echo "OK: tet_standalone release closure is clean"
```

## Runtime smoke test

```elixir
defmodule Tet.Runtime.SmokeStandaloneTest do
  use ExUnit.Case, async: false

  @forbidden_modules [
    Phoenix,
    Phoenix.Endpoint,
    Phoenix.LiveView,
    Phoenix.PubSub,
    Plug,
    Plug.Conn,
    Plug.Cowboy,
    Cowboy
  ]

  test "no web-framework module is loaded" do
    leaked = for mod <- @forbidden_modules, Code.ensure_loaded?(mod), do: mod
    assert leaked == []
  end

  test "no phoenix/plug/cowboy app is started" do
    started = Application.started_applications() |> Enum.map(&elem(&1, 0))

    leaked = Enum.filter(started, fn app ->
      s = Atom.to_string(app)
      String.starts_with?(s, "phoenix") or String.starts_with?(s, "plug") or s == "cowboy"
    end)

    assert leaked == []
  end

  test "Tet facade is reachable" do
    assert function_exported?(Tet, :doctor, 1)
  end
end
```

## Acceptance runner

```bash
#!/usr/bin/env bash
set -euo pipefail

tools/check_imports.sh
tools/check_xref.sh
mix compile --warnings-as-errors
mix test
MIX_ENV=test mix test --only smoke_standalone
tools/check_release_closure.sh

if [ -d apps/tet_web_phoenix ]; then
  mv apps/tet_web_phoenix /tmp/tet_web_phoenix_backup
  trap 'mv /tmp/tet_web_phoenix_backup apps/tet_web_phoenix' EXIT
  mix compile --warnings-as-errors
  mix test
  MIX_ENV=prod mix release tet_standalone --overwrite
fi

echo "ALL ACCEPTANCE CHECKS PASSED"
```
