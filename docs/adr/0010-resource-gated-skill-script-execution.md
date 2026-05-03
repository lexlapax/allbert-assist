# ADR 0010: Resource-Gated Skill Script Execution

## Status

Accepted for v0.09 planning.

## Context

Agent Skills may include `scripts/`, but Allbert has intentionally kept those
resources inert through v0.08. ADR 0003 made skill folders manifests and
resources, not executable authority. ADR 0007 requires runtime-facing side
effects to enter through registered Jido actions. ADR 0008 requires durable
confirmation for risky work. ADR 0009 defines Level 1 local policy sandboxing
as host-process execution with command, cwd, env, timeout, output, trace, and
audit controls, not OS isolation.

v0.09 needs to run trusted bundled skill scripts without turning every skill
folder, script path, or model-selected command into executable authority.

Level 1 host execution cannot protect the host from hostile code and cannot
guarantee network isolation inside an arbitrary script. Therefore v0.09 must be
for trusted, explicitly selected, inventoried skill scripts only. Untrusted
online skills, package installs, external service calls, and generic scripting
engines require later milestones or deeper sandbox backends.

## Decision

Allbert will introduce resource-gated skill script execution.

The only script execution entrypoint is a registered Jido action named
`run_skill_script`. It may execute a script only when the script is part of the
selected skill's parsed `AllbertAssist.Skills.Resource` inventory with
`kind: :script`, the skill is trusted and enabled, the validated capability
contract allows the action, Security Central returns a confirmation-eligible
decision for `:skill_script_execute`, and the operator approves a durable
confirmation.

The script path is a resource identifier, not a filesystem authority. The
action must reject absolute paths, traversal, hidden path segments, missing
resources, non-script resources, and digest mismatches. The resource digest
must be checked before pending creation and again immediately before approved
execution.

The runner must use explicit executable plus argv. Shell strings, command
chaining, redirection, command substitution, backgrounding, PTY sessions,
package bootstrap, and daemon management are outside v0.09. Direct executable
script resources are the first supported launch mode. Interpreter profiles may
be added through Settings Central, but broad default interpreter execution is
not granted by file extension alone.

Skill activation remains progressive disclosure only. Activating or reading a
skill may load instructions and resource metadata, but never runs scripts.

## Consequences

- v0.09 adds real script execution for trusted inventoried resources, not a
  generic scripting engine.
- Security Central gains a `:skill_script_execute` permission with a
  confirmation safety floor.
- Settings Central gains an `execution.skill_scripts.*` namespace.
- Confirmation records, traces, audits, CLI, and LiveView must show skill
  name, script path, digest, cwd, args summary, timeout, output cap, and result.
- Imported or untrusted skills remain non-executable until explicit trust,
  enablement, validation, and confirmation.
- v0.09 may reuse Level 1 local runner primitives, but documentation must not
  claim container, remote, microVM, or network isolation.
- v0.10 owns package installs, external services, and online skill import under
  ADR 0011. Imported skills remain disabled and untrusted after import; v0.10
  must not make imported skill scripts executable by import alone.
- Future untrusted-code execution should graduate to Level 2, Level 3, or
  Level 4 sandbox planning instead of widening v0.09 semantics.
