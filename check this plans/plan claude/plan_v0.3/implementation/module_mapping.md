# Implementation — Module Mapping

## `tet_core`

```text
apps/tet_core/lib/tet/
  workspace.ex
  session.ex
  task.ex
  message.ex
  tool_run.ex
  approval.ex
  artifact.ex
  event.ex
  command.ex
  error.ex
  ids.ex
  redactor.ex
  policy/
    policy.ex
    path_policy.ex
    mode_policy.ex
    trust_policy.ex
    approval_policy.ex
    command_policy.ex
  patch/
    patch.ex
    approval.ex
  llm/
    provider.ex
    event.ex
  tool.ex
  store.ex
```

## `tet_runtime`

```text
apps/tet_runtime/lib/
  tet.ex                         public facade
  tet/application.ex
  tet/runtime.ex
  tet/event_bus.ex
  tet/runtime/
    session_registry.ex
    session_supervisor.ex
    session_worker.ex
  tet/agent/
    runtime_supervisor.ex
    runtime.ex
    loop.ex
    tool_intent_parser.ex
    context_builder.ex
    limits.ex
  tet/prompt/
    composer.ex
    defaults.ex
    file_store.ex
    tool_cards.ex
    debug.ex
  tet/tool/
    executor.ex
    task_supervisor.ex
    registry.ex
  tet/tools/
    local_fs.ex
    search.ex
    git.ex
    patch.ex
    verifier.ex
  tet/verification/
    runner.ex
    task_supervisor.ex
  tet/storage/
    supervisor.ex
    dispatcher.ex
```

## `tet_cli`

```text
apps/tet_cli/lib/tet/cli/
  main.ex
  argv.ex
  commands/
    doctor.ex
    init.ex
    workspace.ex
    session.ex
    chat.ex
    ask.ex
    explore.ex
    edit.ex
    approvals.ex
    patch_approve.ex
    patch_reject.ex
    verify.ex
    status.ex
    prompt_debug.ex
    events_tail.ex
  render/
    timeline.ex
    diff.ex
    tool_run.ex
    verifier.ex
    errors.ex
  exit_codes.ex
```

## `tet_store_sqlite`

```text
apps/tet_store_sqlite/lib/tet/store/sqlite/
  application.ex
  repo.ex
  store.ex
  migrations.ex
  schemas/
    workspace.ex
    session.ex
    task.ex
    message.ex
    tool_run.ex
    approval.ex
    artifact.ex
    event.ex
```

## `tet_web_phoenix` optional

```text
apps/tet_web_phoenix/lib/
  tet_web_phoenix/application.ex
  tet_web/endpoint.ex
  tet_web/router.ex
  tet_web/live/
    dashboard_live.ex
    session_live.ex
    approval_live.ex
    prompt_debug_live.ex
  tet_web/components/
    timeline_component.ex
    diff_component.ex
    tool_run_component.ex
    verifier_component.ex
```
