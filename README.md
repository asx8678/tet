<div align="center">

<pre>
╭──────────────────────────────────────────────────────────────────────────────────────────────╮
│ △  TET CLI        ORBITAL OBSERVATION INTERFACE        LINK: ORBITAL │ SECURE │ NODE: TET-01 │
╰──────────────────────────────────────────────────────────────────────────────────────────────╯
</pre>

[![status](https://img.shields.io/badge/STATUS-OPERATIONAL-FF2E2E?style=flat-square&labelColor=0A0D0F)](#system-status)
[![agent](https://img.shields.io/badge/AGENT-ONLINE-FF2E2E?style=flat-square&labelColor=0A0D0F)](#agent-status)
[![elixir](https://img.shields.io/badge/ELIXIR-1.16%2B-FF2E2E?style=flat-square&labelColor=0A0D0F&logo=elixir&logoColor=white)](https://elixir-lang.org)
[![otp](https://img.shields.io/badge/OTP-27%2B-FF2E2E?style=flat-square&labelColor=0A0D0F&logo=erlang&logoColor=white)](https://www.erlang.org)
[![mode](https://img.shields.io/badge/MODE-ASCII-FF2E2E?style=flat-square&labelColor=0A0D0F)](#orbital-feed--ascii-render)

<sub><code>TET CLI v0.1.0</code> · <code>ORBITAL NODE SYNCHRONIZED</code> · <code>ASCII MODE ■</code></sub>

</div>

---

<table>
<tr>
<td width="28%" valign="top">

<h3>COMMAND INTERFACE</h3>

<pre><code>tet ~

# quick scan
tet help
tet ask "hello standalone"
tet ask --session demo "second turn"

# session telemetry
tet sessions
tet session show demo
tet events --session demo
tet timeline --session demo

# node maintenance
tet doctor
tet sync memory</code></pre>

<h3 id="system-status">SYSTEM STATUS</h3>

<pre><code>NODE ID      TET-01
AGENT        STREAMING-CHAT
MODE         STANDALONE / OTP
STATUS       OPERATIONAL
AUTH         VERIFIED
SESSION      02:14:55</code></pre>

<h3>TARGET PROFILE</h3>

<pre><code>TARGET ID    OMN-687
CLASS        UNKNOWN
TYPE         NON-BIOLOGICAL
SIZE         1.2 km
BEHAVIOR     STATIONARY ORBIT
THREAT       LOW</code></pre>

</td>
<td width="44%" valign="top">

<h3 id="orbital-feed--ascii-render">ORBITAL FEED · ASCII RENDER</h3>

<pre><code>                         .::;:,,.
                         ,,;isXA222AAXXsXsii;:::.
                          .     ,:irXA25553MHB@@S35AXsri;::,.
                           .         .,;sA5MS@@@#M322AAAXAAXXXXXXXssri;:.
                           .,.            ,;s3SSHh522AXAXXXXAA2225352Xsi,
                            .:.               ,;;is22AAXAXXXA2Xii::..
                             ,:. .                 :;iiirrsAsr,      .
...                           ,:..,,..                    ...
,::;iiiii;:,                   ,;,.::...             .   ...       .
  ....,:;irssXsr;:.             ,r;,::,....           .  ..      .
       .. ..,::irXXXXs;,         :X;::;,,,,..          ,..     .
..,,,,..   ......,,,;irsXss;,     :s;,,;:,,...        ..,    ..
   .,,:;;:. .,,,,::,,...,,;rXXXi:  ,i,..:,...        ...   ..
       .,:;;.  .,,,::,.    ..,;irXs;i;,..:..         ..   ..
            ,::.   ..,,.      ...,:irs:. .,.     .  .,  ..
       .,.     ..     ,:;,.       ...,;:,  ,    .  .. ,.
       .,,:..           .:;,. .   .. ..:,. ..  .  ..,,.
           .,::,       .  .;;:,,,.   .. ::. ...  ,:iXs:.
              ....          .::,,.,.  .. ,:. .  ,;i:,:issi:.
                 ...          .,::,,,.  . .:.  :;:,.....,;rss;,
                                   .,,,..  .:.;i.   ...  . .,;rr;.
                                        .    ..        . ..   .,:;;,
                                                                   .,

            TARGET LOCK: OMN-687 · THREAT LEVEL: LOW</code></pre>

<h3>MISSION BRIEF</h3>

<pre><code>TET is a standalone terminal interface for streaming chat,
session resume, event telemetry, Prompt Lab history, autosave
checkpoints, provider routing, and durable local storage.</code></pre>

</td>
<td width="28%" valign="top">

<h3>ENVIRONMENT</h3>

<pre><code>SIGNAL STRENGTH    [██████████████░]  93%
SIGNAL QUALITY     [█████████████░░]  92%
SURFACE INTEGRITY  [████████████░░░]  88%
THERMAL STABILITY  [████████████░░░]  85%
POWER RESERVE      [██████████████░]  96%
ORBITAL LOCK       [███████████████] 100%
SENSORS ONLINE     [███████████████] 12/12
DATA LINK                         STABLE</code></pre>

<h3>OBJECT DATA</h3>

<pre><code>TARGET ID     OMN-687
CLASS         UNKNOWN
TYPE          NON-BIOLOGICAL
MASS          N/A
BEHAVIOR      STATIONARY ORBIT
THREAT LEVEL  LOW</code></pre>

<h3>BUILD PIPELINE</h3>

<pre><code>SCAFFOLD  ●━━━━━━━━━━━━━━━━ COMPLETE
CODEGEN   ●━━━━━━━━━━━━━━━━ COMPLETE
PATCH     ●━━━━━━━━━━━━━━━━ COMPLETE
BUILD     ◐━━━━━━━━━━━━━━━━ IN PROGRESS
PREVIEW   ○━━━━━━━━━━━━━━━━ PENDING</code></pre>

</td>
</tr>
</table>

---

## ▣ SUBSYSTEM MAP

The `tet_standalone` release contains four conceptual applications. Each owns exactly one boundary.

| Channel | Boundary role | Signal |
|---|---|---|
| `tet_core` | Pure domain/contracts: `%Tet.Event{}`, `%Tet.Message{}`, `%Tet.Session{}`, `%Tet.Autosave{}`, `Tet.Prompt`, `Tet.Compaction`, `Tet.PromptLab`, `Tet.Tool` read-only contracts, `Tet.ModelRegistry`, `Tet.Provider`, `Tet.Store` | `PURE` |
| `tet_store_sqlite` | Default standalone store adapter: durable JSON Lines messages, sessions, autosave checkpoints, event timeline, and Prompt Lab history | `DURABLE` |
| `tet_runtime` | OTP supervision tree, Registry-backed event bus, public `Tet.*` facade, provider routing, mock and OpenAI-compatible adapters | `ONLINE` |
| `tet_cli` | Thin terminal adapter calling only the public facade | `TERMINAL` |

```text
BOUNDARY LAW
No Phoenix, LiveView, Plug, Cowboy, Bandit, or web adapter dependency is part
of the standalone path. Architectural lasagna remains illegal.
```

---

## ▣ RUNTIME REQUIREMENTS

```text
ERLANG/OTP      >= 27.0        built-in :json module required
ELIXIR          >= 1.16        pinned in mix.exs
RELEASE         tet_standalone standalone closure
STORE           durable local JSON Lines + SQLite adapter boundary
```

---

## ▣ OPERATOR RUNBOOK

From the repository root:

```bash
mix format --check-formatted
mix web.facade_contract
mix test
tools/check_web_removability.sh
MIX_ENV=prod mix release tet_standalone --overwrite
tools/check_release_closure.sh --no-build
```

Run the full standalone boundary alias:

```bash
mix standalone.check
```

---

## ▣ AGENT STATUS

<table>
<tr>
<td width="38%" valign="top">

<pre><code>          △
        △░░△
      △░▓▓░△
    △░▓██▓░△
      ▽▓░░▓▽
        ▽▽</code></pre>

</td>
<td width="62%" valign="top">

<pre><code>STATUS       ONLINE
QUEUE        2
MEMORY       SYNCED
SAFETY       ENABLED
AUTONOMY     ACTIVE</code></pre>

</td>
</tr>
</table>

Smoke test streaming + session resume with the deterministic mock provider and a disposable store:

```bash
STORE=$(mktemp /tmp/tet-session-smoke.XXXXXX)

TET_PROVIDER=mock TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet ask --session smoke "first"

TET_PROVIDER=mock TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet ask --session smoke "second"

TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet session show smoke

TET_STORE_PATH="$STORE" \
  _build/prod/rel/tet_standalone/bin/tet events --session smoke
```

---

## ▣ CODEGEN TELEMETRY

```text
FILE        src/core/agent.ex
TOKENS      1,842
QUALITY     HIGH
PROGRESS    [████████████░░░] 84%
```

```text
[2026-05-01 14:02:17]  [SYS]  agent online
[2026-05-01 14:02:21]  [GEN]  generating module apps/tet_core/lib/event.ex
[2026-05-01 14:02:31]  [GEN]  writing function handle_event/3
[2026-05-01 14:02:41]  [REF]  cleaned dashboard component
[2026-05-01 14:02:48]  [PAT]  patch applied
[2026-05-01 14:02:55]  [BLD]  preview build ready
[2026-05-01 14:03:02]  [MEM]  memory sync complete
tet ~ ▌
```

---

## ▣ DEEPER DOCS

| Document | Purpose |
|---|---|
| [`docs/README.md`](docs/README.md) | Standalone closure, session resume, doctor, providers, registry, Prompt Lab, autosave, compaction |
| [`docs/prompt_contract.md`](docs/prompt_contract.md) | Pure prompt build contract |
| [`docs/prompt_lab.md`](docs/prompt_lab.md) | Advisory prompt refinement and history store |
| [`docs/model_registry.md`](docs/model_registry.md) | Editable, offline model registry schema |
| [`docs/adr/`](docs/adr/) | Architecture decision records |

---

<div align="center">

<pre>
╭──────────────────────────────────────────────────────────────────────────────╮
│ TET CLI v0.1.0              ORBITAL NODE SYNCHRONIZED              ASCII ■ │
╰──────────────────────────────────────────────────────────────────────────────╯
</pre>

</div>
