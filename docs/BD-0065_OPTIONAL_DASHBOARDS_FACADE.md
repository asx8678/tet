# BD-0065 — Optional dashboards via facade

Status: Implemented adapter shell
Issue: `tet-db6.65` / `BD-0065`

## Summary

`apps/tet_web_phoenix` is present as a dependency-free optional adapter shell.
It intentionally does **not** add Phoenix, LiveView, Plug, Cowboy, endpoint,
router, PubSub, assets, migrations, or web-owned persistence.

The shell provides renderable dashboard projections for:

- timeline;
- tasks;
- artifacts;
- repair;
- remote status.

Every dashboard is an Event Log projection. The loader path calls only the root
`Tet.list_events/1` or `Tet.list_events/2` facade, then transforms `%Tet.Event{}`
records into presentation maps and escaped fallback HTML. A future Phoenix
LiveView release can wrap these projection modules without moving state,
policy, repair, remote-worker lifecycle, providers, tools, or stores into the
web adapter.

## Public shape

```elixir
TetWebPhoenix.dashboard_names()
TetWebPhoenix.dashboard(:timeline, session_id: "session-id")
TetWebPhoenix.render_dashboard(:tasks, session_id: "session-id")
TetWebPhoenix.Dashboard.assigns(:remote_status, session_id: "session-id")
```

The returned projection maps include:

- `:source` set to `:event_log`;
- dashboard `:id` and `:title`;
- `:event_count` for loaded events;
- `:row_count` for rows matching that projection;
- `:rows` containing HTML-friendly values derived from Event Log records only.

The fallback HTML uses `data-source="event-log"` and escapes row data. It is not
a replacement for real LiveView templates; it is the adapter seam and rendering
contract that real templates can reuse.

## Boundary notes

The web app depends only on `:tet_core` and `:tet_runtime`. It does not depend on
CLI, store, provider, Phoenix, LiveView, Plug, Cowboy, or persistence libraries.

The implementation avoids web-owned domain namespaces and persistence. Dashboard
filters are intentionally heuristic over event payload/metadata keys so future
runtime events can become visible without teaching the web adapter any state
machine semantics.
