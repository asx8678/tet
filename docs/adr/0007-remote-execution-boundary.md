# ADR-0007 — Remote execution boundary

Status: Accepted
Date: 2026-04-30
Issue: `tet-db6.2` / `BD-0002`

## Context

The global vision includes optional remote SSH workers. Some earlier v1-focused plans explicitly defer remote execution. These positions are compatible if the ADR separates architecture boundary from delivery phase.

Remote execution expands the attack surface, increases uncertainty, and makes “oops I ran that on the wrong machine” a very expensive sentence. It must therefore be controlled by the local runtime and the same gates as local execution.

Primary sources:

- `plans/ELIXIR_CLI_AGENT_GLOBAL_VISION.md`
- `plans/ELIXIR_CLI_AGENT_PHASED_IMPLEMENTATION.md`
- `check this plans/plan 3/plan/docs/05_tools_policy_approvals_verification.md`
- `check this plans/plan claude/plan_v0.3/upgrades/13_operations_and_telemetry.md`
- [BD-0001 source inventory and missing-input report](../research/BD-0001_SOURCE_INVENTORY_AND_MISSING_INPUT_REPORT.md)

## Decision

Remote execution is an optional runtime capability with an SSH-first boundary. It is not required for the initial standalone CLI foundation, but any future remote implementation must follow this ADR.

The local Tet runtime remains the control plane:

- local workspace/session/task/profile/policy state remains authoritative;
- remote hosts are less-trusted execution targets;
- remote workers are started, monitored, cancelled, and merged by `tet_runtime` services;
- CLI and optional Phoenix operate remote workflows only through `Tet.*`;
- remote results return as Event Log entries and Artifact Store references before any local mutation.

Remote profiles must be explicit configuration. A remote profile includes at minimum host alias, host, port, user, host-key fingerprint, auth secret reference, remote workdir, allowed commands/verifiers, environment policy, file-sync policy, sandbox profile, network policy, max runtime, artifact caps, and repair eligibility.

Remote execution lifecycle:

1. Validate profile, trust, task category, policy, approval requirements, and host key.
2. Establish SSH using scoped secret references, not raw master secrets copied into config or prompt context.
3. Bootstrap or verify a remote worker script/binary within the scoped workdir.
4. Create a remote lease and heartbeat record.
5. Execute named tools/verifiers or approved remote actions only.
6. Stream stdout, stderr, logs, diffs, snapshots, and metadata as redacted artifacts.
7. Support cancellation tokens and reconnect/resync windows.
8. Mark uncertain outcomes explicitly when heartbeat or reconnect fails.
9. Merge results locally through Event Log, Artifact Store, approvals, checkpoints, and policy.
10. Clean up remote leases according to profile policy.

Remote workers must not silently mutate the local workspace. Remote diffs, generated files, verifier output, and logs become artifacts. Applying any resulting local patch follows the same approval and patch-apply model as local execution.

Remote execution must not require Phoenix. Phoenix may render remote worker status or send approved remote commands through `Tet.*`, but the remote supervisor/lifecycle belongs to runtime.

## Conflict resolution

If a future phase treats remote execution as v1-critical before the standalone CLI and local gates work, defer it. Safety rails first, rocket skates later.

If a remote design requires a web server, Phoenix channel, or browser session as the control plane, reject it.

If a remote worker requires raw provider keys, SSH private keys, or master secrets in its prompt/config payload, reject it. Secrets are referenced and scoped.

If a remote command bypasses task/category gates, policy, approvals, artifacts, or Event Log capture, reject it.

If Codex exec-server ideas are reused, treat them as protocol inspiration, not permission to bypass Tet's store, policy, or approval model.

## Consequences

- Remote support depends on the gate/approval model, Artifact Store, Event Log, checkpointing, and secrets boundaries being stable first.
- Remote tests need host-key failure, heartbeat loss, cancellation, artifact streaming, reconnect/resync, and merge-path fixtures.
- Remote uncertainty is a first-class state. The runtime must not pretend a network failure means success or failure without evidence.
- Remote worker status can be rendered by CLI, TUI, or Phoenix without changing the control-plane owner.

## Review checklist

- [ ] Local runtime remains the remote control plane.
- [ ] Remote profiles use scoped secret references and host-key validation.
- [ ] Remote actions pass the same task, hook, policy, approval, artifact, and event gates as local actions.
- [ ] Remote results merge locally through artifacts and approvals; they do not silently mutate the local workspace.
- [ ] Phoenix is not required for remote execution.
