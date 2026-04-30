# Model registry schema (BD-0013)

Tet's model registry is an editable, offline JSON contract describing provider
families, concrete models, model capabilities, and profile-specific model pins.
It is deliberately **not** a provider router yet. Tiny steps, fewer haunted
abstractions.

The pure schema/validator lives in `tet_core` as `Tet.ModelRegistry`. Runtime IO
lives in `tet_runtime` as `Tet.Runtime.ModelRegistry`, which reads JSON and then
hands decoded data to the core validator. The loader never calls a provider,
never fetches remote model metadata, and never touches any web stack.

## Load order

`Tet.Runtime.ModelRegistry.path/1` chooses a registry path in this order:

1. explicit runtime option: `model_registry_path: "/path/to/models.json"`;
2. environment variable: `TET_MODEL_REGISTRY_PATH`;
3. application config: `config :tet_runtime, :model_registry_path, "/path"`;
4. bundled default: `apps/tet_runtime/priv/model_registry.json` in source, copied
   to the release under the `tet_runtime` app priv directory.

Load it through the standalone facade:

```elixir
{:ok, registry} = Tet.model_registry()
{:ok, registry} = Tet.model_registry(model_registry_path: "/tmp/tet-models.json")
```

Or through runtime diagnostics:

```elixir
{:ok, report} = Tet.Runtime.ModelRegistry.diagnose()
{:error, report} = Tet.Runtime.ModelRegistry.diagnose(model_registry_path: "bad.json")
```

## Top-level shape

```json
{
  "schema_version": 1,
  "providers": {},
  "models": {},
  "profile_pins": {}
}
```

| Field | Type | Required | Meaning |
|---|---:|---:|---|
| `schema_version` | positive integer | yes | Version of this registry schema. BD-0013 defines version `1`. |
| `providers` | object keyed by provider id | yes | Provider families/config buckets available to later routing code. |
| `models` | object keyed by registry model id | yes | Concrete model declarations and capabilities. |
| `profile_pins` | object keyed by profile id | yes | Per-profile default/fallback model choices. |

The validator accepts decoded JSON maps and Elixir maps. JSON object keys are
strings; Elixir atom keys are also accepted for static field names and ids.
Normalized registry data uses atom field names and string ids.

## Providers

Provider ids are stable registry ids such as `mock` or `openai_compatible`.
A provider entry declares the provider family and non-secret configuration.

```json
{
  "providers": {
    "openai_compatible": {
      "type": "openai_compatible",
      "display_name": "OpenAI-compatible chat completions",
      "config": {
        "base_url": "https://api.openai.com/v1",
        "api_key_env": "TET_OPENAI_API_KEY",
        "model_env": "TET_OPENAI_MODEL"
      }
    }
  }
}
```

| Field | Type | Required | Meaning |
|---|---:|---:|---|
| `type` | non-empty string | yes | Provider adapter family/type. The bundled registry uses `mock` and `openai_compatible`. |
| `display_name` | non-empty string | no | Human-readable label. Defaults to the provider id. |
| `config` | object | no | Non-secret provider config, for example `base_url` or env-var names. Defaults to `{}`. |

Secrets do **not** belong in the registry. Store secret names such as
`api_key_env`, not API keys. Existing provider config still reads secrets from
environment variables/runtime opts; BD-0013 only declares the registry contract.

## Models

Model ids are Tet-facing ids, not necessarily provider wire names. A model entry
points to a provider id, names the provider-side model string, and declares the
capabilities the future router must check before selecting it.

```json
{
  "models": {
    "openai/gpt-4o-mini": {
      "provider": "openai_compatible",
      "model": "gpt-4o-mini",
      "display_name": "GPT-4o mini",
      "capabilities": {
        "context": {
          "window_tokens": 128000,
          "max_output_tokens": 16384
        },
        "cache": {
          "supported": true,
          "prompt": true
        },
        "tool_calls": {
          "supported": true,
          "parallel": true
        }
      },
      "config": {}
    }
  }
}
```

| Field | Type | Required | Meaning |
|---|---:|---:|---|
| `provider` | provider id | yes | Must reference an id in `providers`. |
| `model` | non-empty string | yes | Provider API model name sent by a future adapter/router. |
| `display_name` | non-empty string | no | Human-readable label. Defaults to the registry model id. |
| `capabilities` | object | yes | Required `context`, `cache`, and `tool_calls` declarations. |
| `config` | object | no | Model-specific non-secret config/overrides. Defaults to `{}`. |

### Context capability

```json
"context": {
  "window_tokens": 128000,
  "max_output_tokens": 16384
}
```

| Field | Type | Required | Meaning |
|---|---:|---:|---|
| `window_tokens` | positive integer | yes | Maximum total context window advertised for the model. |
| `max_output_tokens` | positive integer | no | Maximum output budget if known. It must not exceed `window_tokens`. |

A model without `capabilities.context.window_tokens` is invalid. Future prompt
compaction/router work will use this value to reject or compact requests before
the provider call, instead of discovering context-length errors from a remote API
after wasting time. Revolutionary stuff: measure before bonking the wall.

### Cache capability

```json
"cache": {
  "supported": true,
  "prompt": true
}
```

| Field | Type | Required | Meaning |
|---|---:|---:|---|
| `supported` | boolean | yes | Whether the model/provider exposes a usable prompt/cache feature. |
| `prompt` | boolean | no | Whether prompt-prefix caching is available/meaningful. |
| `read` | boolean | no | Reserved declaration for explicit cache reads. |
| `write` | boolean | no | Reserved declaration for explicit cache writes. |

The validator only checks the declaration shape. It does not enable caching and
it does not try to infer provider pricing. Future provider routing can strip or
add cache-control hints based on this capability.

### Tool-call capability

```json
"tool_calls": {
  "supported": true,
  "parallel": true
}
```

| Field | Type | Required | Meaning |
|---|---:|---:|---|
| `supported` | boolean | yes | Whether the model can emit tool/function calls. |
| `parallel` | boolean | no | Whether the model can request multiple tool calls in one response. Defaults to `false`. |

Future explore/execute profiles should require `tool_calls.supported == true`.
Pure chat profiles may pin models without tool support.

## Profile pins

Profile pins declare default and fallback model ids per runtime/profile mode.
They are intentionally simple because the actual router scoring/fallback logic is
a later issue, and we are not feeding the abstraction gremlin after midnight.

```json
{
  "profile_pins": {
    "tet_standalone": {
      "default_model": "mock/default",
      "fallback_models": []
    },
    "chat": {
      "default_model": "openai/gpt-4o-mini",
      "fallback_models": ["mock/default"]
    }
  }
}
```

| Field | Type | Required | Meaning |
|---|---:|---:|---|
| `default_model` | model id | yes | Must reference an id in `models`. |
| `fallback_models` | array of model ids | no | Ordered fallback candidates, each referencing `models`. Defaults to `[]`. |

## Validation errors

`Tet.ModelRegistry.validate/1` and `Tet.ModelRegistry.from_json/1` return either:

```elixir
{:ok, registry}
```

or:

```elixir
{:error,
 [
   %Tet.ModelRegistry.Error{
     path: ["models", "openai/gpt-4o-mini", "capabilities", "context", "window_tokens"],
     code: :invalid_type,
     message: "models.openai/gpt-4o-mini.capabilities.context.window_tokens must be positive integer",
     details: %{expected: "positive integer", actual: "string"}
   }
 ]}
```

Error fields:

| Field | Meaning |
|---|---|
| `path` | Machine-readable path into the registry data. List elements are strings or list indexes. |
| `code` | Stable atom such as `:required`, `:invalid_type`, `:invalid_value`, `:unknown_reference`, `:invalid_json`, or `:registry_unreadable`. |
| `message` | Human-readable fix hint. Good for CLI/doctor output. |
| `details` | Structured context such as expected/actual types or allowed reference ids. |

Use `Tet.ModelRegistry.format_error/1` when a single-line human string is enough.
Do not parse `message`; use `path`, `code`, and `details` for program logic.

## How the future provider router consumes this

The later router should treat the normalized registry as read-only input:

1. Load registry through `Tet.model_registry/1` or `Tet.Runtime.ModelRegistry.load/1`.
2. Fetch the active profile pin with `Tet.ModelRegistry.profile_pin/2`.
3. Build candidate models from `default_model` plus `fallback_models`.
4. Filter candidates by required capabilities:
   - prompt token estimate <= `capabilities.context.window_tokens`;
   - cache hints only when `capabilities.cache.supported` is true;
   - tool profiles only when `capabilities.tool_calls.supported` is true;
   - parallel tool dispatch only when `capabilities.tool_calls.parallel` is true.
5. Resolve provider config by joining `model.provider` to `registry.providers`.
6. Pass provider-side `model.model` and non-secret config to the adapter.
7. Emit timeline events if a fallback swaps model/provider, so operators can see
   the change instead of enjoying surprise production jazz.

BD-0013 stops at the schema, default JSON, loader, validation, tests, and docs.
It does not change current provider selection, does not make network calls, does
not add a web dependency, and does not introduce `models.dev` or any remote
registry refresh path.
