# Tet Prompt Lab model

`Tet.PromptLab` is the pure Prompt Lab contract introduced for `BD-0047`.
It analyzes and improves prompt text without executing tools, calling providers,
reading workspace files, mutating chat sessions, or writing runtime events.

Prompt Lab is intentionally advisory. It returns a better prompt plus structured
quality feedback. A caller may copy the refined prompt into a later chat turn,
but that is an explicit caller action, not automatic execution. No shell goblins,
thank you.

## Boundary

Core model:

```elixir
Tet.PromptLab.boundary()
#=> %{
#=>   side_effects: false,
#=>   executes_tools: false,
#=>   calls_providers: false,
#=>   reads_workspace: false,
#=>   mutates_runtime_state: false,
#=>   runtime_allowed_store_writes: [:prompt_history]
#=> }
```

Runtime facade:

```elixir
Tet.prompt_lab_presets()
Tet.get_prompt_lab_preset("coding")
Tet.refine_prompt("Implement the CLI command", preset: "coding")
Tet.list_prompt_history()
Tet.fetch_prompt_history("prompt-history-...")
```

`Tet.refine_prompt/2` returns `{:ok, %{refinement: result, history: entry | nil}}`.
Pass `persist?: false` for a pure preview that does not resolve or call any store
adapter.

When persistence is enabled, runtime may call only the Prompt Lab history store
callbacks. It must not call message, session, autosave, event, provider, tool,
or chat execution paths.

## Presets

Built-in presets are versioned with `tet.prompt_lab.preset.v1` and validated by
`Tet.PromptLab.Preset`.

Current presets:

| Preset id | Purpose |
|---|---|
| `general` | Balanced prompt review for everyday analysis, writing, and coordination. |
| `coding` | Software-development prompts with implementation boundaries and validation detail. |
| `planning` | Planning prompts with scope, dependencies, risks, milestones, and decisions. |

A preset contains:

- `id`;
- `version`;
- `name`;
- `description`;
- `dimensions`;
- `instructions`;
- `tags`;
- `output_style`;
- `metadata`.

For `BD-0047`, presets are built in and read-only. Writable custom preset
storage is deliberately out of scope; future work can add read-only custom
preset loading behind the same validation contract.

## Quality dimensions

Quality dimensions are versioned with `tet.prompt_lab.dimension.v1`. Scores use
a 1..10 scale where higher is better.

| Dimension id | Meaning |
|---|---|
| `clarity_specificity` | Objective, subject, and expected work product are concrete. |
| `context_completeness` | Relevant project, audience, environment, files, or background are present. |
| `constraint_handling` | Boundaries, non-goals, limitations, and requirements are explicit. |
| `ambiguity_control` | Vague references and competing interpretations are reduced. |
| `actionability` | Deliverables, output format, success criteria, and validation are clear. |

`ambiguity_control` is intentionally framed as higher-is-better: less ambiguity
means a higher score.

## Refinement request

A request is explicit caller-supplied data validated by
`Tet.PromptLab.Request`:

| Field | Type | Notes |
|---|---|---|
| `prompt` | non-empty string | Original prompt text to improve. |
| `preset_id` | string | Built-in preset id. |
| `dimensions` | list of strings | Optional subset of the selected preset dimensions. |
| `metadata` | map | Normalized JSON-like caller metadata. Sensitive keys are redacted in debug output. |

Prompt Lab does not automatically read chat history, files, rules, or autosave
snapshots. If a caller wants context considered, it must put that context in the
prompt or metadata explicitly.

## Refinement output

Refiner output is validated by `Tet.PromptLab.Refinement` and versioned with
`tet.prompt_lab.refinement.v1`.

The result contains:

| Field | Description |
|---|---|
| `id` | Stable/generated `prompt-refinement-...` id unless supplied by fixtures. |
| `preset_id` / `preset_version` | Preset used for the refinement. |
| `status` | `improved`, `needs_clarification`, or `unchanged`. |
| `original_prompt` / `refined_prompt` | Raw prompt text inside the dedicated result/history contract. |
| `summary` | Human-readable result summary. |
| `scores_before` / `scores_after` | Dimension keyed score/comment maps. |
| `changes` | Dimension-linked rationales for improvements. |
| `questions` | Clarifying questions when missing input would otherwise require guessing. |
| `warnings` | Safety notes, especially for prompts that mention tools/commands. |
| `safety` | Explicit booleans proving tools/providers/outside mutations were not used. |
| `metadata` | Normalized result metadata. |
| `original_sha256` / `refined_sha256` | Raw prompt content hashes for audit/debug. |

No executable output fields are valid. `tool_calls`, commands, patches, shell
plans, provider request bodies, and similar runnable shapes are rejected by the
refinement validator rather than quietly ignored.

Use `Tet.PromptLab.debug/1` or `Tet.PromptLab.debug_text/1` for redacted debug
snapshots. Debug output includes hashes, scores, counts, safety flags, and
redacted metadata, but not raw original or refined prompt text.

## Prompt history storage

Prompt history entries are validated by `Tet.PromptLab.HistoryEntry` and
versioned with `tet.prompt_lab.history.v1`.

A history entry records:

- `id`;
- `created_at`;
- validated request;
- validated refinement result;
- history metadata.

The core `Tet.Store` behaviour owns these callbacks:

```elixir
save_prompt_history(history_entry, opts)
list_prompt_history(opts)
fetch_prompt_history(history_id, opts)
```

The default standalone adapter appends JSON Lines to:

```text
.tet/prompt_history.jsonl
```

The path is derived from `TET_STORE_PATH` or the configured message path. It can
be overridden with:

- runtime option `:prompt_history_path`;
- runtime option `:prompt_lab_history_path`;
- environment variable `TET_PROMPT_HISTORY_PATH`;
- application config `:tet_runtime, :prompt_history_path`.

Prompt history is separate from messages, autosaves, and events so the mutation
boundary is auditable. Saving Prompt Lab history must not create chat messages,
autosave checkpoints, or runtime timeline rows.

## Future dashboards

Future CLI/TUI/web dashboards should use the public facade:

```elixir
Tet.prompt_lab_presets()
Tet.list_prompt_history()
Tet.fetch_prompt_history(history_id)
```

Dashboards may render presets, quality dimensions, score trends, redacted debug
snapshots, and history entries. They must not read `.tet/prompt_history.jsonl`
directly, call store adapters directly, or run refined prompts automatically.
A future optional Phoenix adapter remains facade-only just like the rest of the
standalone boundary.
