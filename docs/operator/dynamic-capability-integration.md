# Dynamic Capability Integration Operator Guide

Status: v0.37 implementation contract.

v0.37 is the first Allbert path that can turn generated Elixir/OTP source into
live runtime authority. It is default-off, local-only, and reversible. A draft
can become live only after sandbox evidence, trusted validation, and an
operator confirmation.

The shipped v0.37 loader integrates reviewed read-only actions only. Generated
apps, panels, settings fragments, memory namespaces, objective wiring, route
pages, and children remain rejected live targets until later validators exist.

## Authority Model

Keep these states separate when reviewing a dynamic capability:

- Advisory generation writes draft files and metadata. The shipped v0.37
  request scaffold records inert draft metadata only. It grants no authority.
- v0.36 sandbox trial and gate reports are evidence. They grant no authority.
- `:gate_passed` means the draft is eligible for operator review only.
- Security Central confirmation is the trust grant.
- The loader registers only the reviewed source that still matches the gated
  source hash.
- Rollback removes live authority. BEAM module purge is best effort and audited.

Agent output, passing generated tests, and a green sandbox gate cannot integrate
or roll back code by themselves.

## Enablement

Use a disposable Allbert Home for all smoke work:

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v037-operator.XXXXXX)"
mix ecto.migrate.allbert
```

Enable the v0.36 sandbox first and confirm the doctor is green:

```sh
mix allbert.settings set sandbox.elixir.enabled true
mix allbert.sandbox doctor
```

Enable v0.37 generation and live integration separately:

```sh
mix allbert.settings set dynamic_codegen.enabled true
mix allbert.settings set dynamic_codegen.provider_profile local
mix allbert.settings set dynamic_codegen.live_loader_enabled true
mix allbert.settings set dynamic_codegen.allowed_action_permissions '["read_only"]'
```

The workflow still fails closed if the provider profile cannot resolve, the
provider is disabled, a required credential is missing, the sandbox doctor is
not green, or the live loader switch is false.

## Request A Draft

The v0.37 advisory producer is a guarded scaffold. It creates producer-neutral
draft metadata for an explicit operator or objective request and records
provider/budget diagnostics, but it does not call a provider or write live
source in the shipped implementation.

```sh
mix allbert.dynamic drafts request weather_summary "Create a read-only weather summary action"
```

Equivalent runtime entrypoint:

```elixir
AllbertAssist.Actions.Runner.run(
  "request_dynamic_draft",
  %{slug: "weather_summary", summary: "Create a read-only weather summary action"},
  %{actor: "local", channel: :cli, surface: "cli"}
)
```

Low-confidence intent or advisory output cannot call this path by itself.

## Evidence Review

Inspect dynamic artifacts with read-only commands:

```sh
mix allbert.dynamic drafts list
mix allbert.dynamic drafts show <slug>
mix allbert.dynamic integrations show <slug>
```

Review:

- `metadata.yaml` tier, revision, producer, target shapes, source hashes, scan
  paths, compiled paths, static validation status, gate status, confirmation ids,
  diagnostics, and timestamps.
- Sandbox report ids and report paths copied from the v0.36 bundle.
- Generated source under the reserved
  `AllbertAssist.DynamicPlugins.Generated.<Slug>` namespace.
- Generated focused tests as functional evidence only.
- Static validation diagnostics for denied AST forms, protected calls,
  undeclared modules, permission/body mismatch, and collision checks.

The draft root is:

```text
<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/
```

The integrated root is:

```text
<ALLBERT_HOME>/dynamic_plugins/integrated/<slug>/<revision>/
```

Ordinary plugin discovery must not scan either root.

## Confirm Integration

Integration is requested through the registered `integrate_dynamic_draft`
action. When it needs trust, it creates a Security Central confirmation. Approve
only from high-trust operator surfaces allowed by
`dynamic_codegen.integration_approval_surfaces`:

```sh
mix allbert.dynamic drafts integrate <slug>
mix allbert.confirmations list
mix allbert.confirmations show <confirmation-id>
mix allbert.confirmations approve <confirmation-id> --reason "reviewed v0.37 gate evidence"
```

The integration action denies approval from Telegram, email, or cross-channel
surfaces even when global confirmation settings would otherwise permit them.

After approval, inspect the registration state:

```sh
mix allbert.dynamic integrations show <slug>
mix allbert.security review --recent --limit 25
```

Integrated actions resolve through `AllbertAssist.Actions.Registry` and run
through `AllbertAssist.Actions.Runner.run/3`. Dynamic actions cannot shadow
static, plugin, app, or other dynamic action names.

## Rollback

Rollback also requires Security Central confirmation:

```sh
mix allbert.dynamic integrations rollback <slug>
mix allbert.confirmations list
mix allbert.confirmations approve <confirmation-id> --reason "rollback dynamic capability"
mix allbert.dynamic integrations show <slug>
```

Rollback removes dynamic action authority and records the result. Module
purge/delete is attempted, but old code can remain in the VM while old
references drain.

Same-name upgrades require rollback first. v0.37 does not replace a live
revision in place.

## Emergency Disablement

Disable live authority without deleting source:

```sh
mix allbert.dynamic integrations disable
mix allbert.security review --recent --limit 25
```

Disable generation as well:

```sh
mix allbert.settings set dynamic_codegen.enabled false
```

Disable sandbox trials:

```sh
mix allbert.settings set sandbox.elixir.enabled false
mix allbert.settings set permissions.sandbox_trial denied
```

Emergency disablement clears live dynamic actions. It does not delete draft or
integrated source.

## Manual Verification Checklist

- Workflow is disabled by default.
- Sandbox doctor failure blocks trial, gate, and integration.
- Missing or unresolved provider profile blocks generation.
- Draft metadata lives under Allbert Home, not Settings Central.
- Gate pass without confirmation cannot integrate.
- Confirmation from a disallowed surface is denied and audited.
- Tampering with reviewed source after the gate blocks integration.
- A dynamic action can run only after registration through the overlay.
- `dynamic_codegen.live_loader_enabled=false` removes or blocks live authority.
- Rollback removes dynamic action authority and leaves inspectable metadata.
