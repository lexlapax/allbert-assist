# Dynamic Capability Integration Operator Guide

Status: v0.37.5 release contract.

v0.37 is the first Allbert path that can turn generated Elixir/OTP source into
live runtime authority. It is default-off, local-only, and reversible. A draft
can become live only after sandbox evidence, trusted validation, and an
operator confirmation.

The shipped v0.37 loader integrates reviewed action artifacts only: pure
`:read_only` actions and delegated `:memory_write` / `:external_network`
actions. Generated apps, panels, settings fragments, memory namespaces,
objective wiring, route pages, and children remain rejected live targets until
later validators exist.

## Authority Model

Keep these states separate when reviewing a dynamic capability:

- Advisory generation writes source-bearing draft files and metadata. The
  generator is a bounded model-backed committee: Planner, Author, TrialAuthor,
  Critic, and invoked Repair calls emit separate packets with redacted
  provenance. It can author pure read-only action source or delegated
  memory/network action source, generated tests, a manifest, hashes, repair
  history, and budget diagnostics. The provider-call cap applies to the whole
  workflow, not one fixed call per role. It grants no authority.
- v0.36 sandbox trial and gate reports are evidence. They grant no authority.
- `:gate_passed` means the draft is eligible for operator review only.
- Security Central confirmation is the integration trust grant. Delegated
  facade writes still use the facade's ordinary Security Central behavior at
  invocation time.
- The loader registers only the reviewed source that still matches the gated
  source hash.
- Rollback removes live authority. BEAM module purge is best effort and audited.

Agent output, Critic acceptance, passing generated tests, and a green sandbox
gate cannot integrate or roll back code by themselves.

## Enablement

Use a disposable Allbert Home for all smoke work:

```sh
unset DATABASE_PATH
unset ALLBERT_HOME_DIR
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v037-operator.XXXXXX)"
```

Do not run an explicit migration command for this disposable-home
smoke. Dev/test configuration derives the SQLite path as
`$ALLBERT_HOME/db/allbert.sqlite3`, and the first `mix allbert.*`
task runs startup migrations before the normal Repo pool and runtime
supervisors start when that canonical database is missing or empty. A
clean-home validation command should not print `database is locked`;
treat that line as a startup bootstrap defect, not expected noise.

Enable the v0.36 sandbox first and confirm the doctor is green:

```sh
mix allbert.settings set sandbox.elixir.enabled true
mix allbert.sandbox doctor
```

Enable v0.37 generation and live integration separately. For remote smoke work,
source `.env` before starting `mix`, enable the provider you are testing, and
select the matching model profile:

```sh
set -a
source .env
set +a
mix allbert.settings set dynamic_codegen.enabled true
```

Choose exactly one provider profile for each smoke run:

```sh
# Recommended remote coding smoke
mix allbert.settings set providers.gemini.enabled true
mix allbert.settings set dynamic_codegen.provider_profile coding

# OpenAI-backed smoke
mix allbert.settings set providers.openai.enabled true
mix allbert.settings set dynamic_codegen.provider_profile fast

# Anthropic-backed smoke
mix allbert.settings set providers.anthropic.enabled true
mix allbert.settings set dynamic_codegen.provider_profile anthropic_fast

# OpenRouter-backed smoke
mix allbert.settings set providers.openrouter.enabled true
mix allbert.settings set dynamic_codegen.provider_profile openrouter_fast
```

Then finish the shared v0.37 capability-generation settings:

```sh
mix allbert.settings set dynamic_codegen.live_loader_enabled true
mix allbert.settings set dynamic_codegen.allowed_targets action
mix allbert.settings set dynamic_codegen.allowed_action_permissions read_only
```

Use only one `dynamic_codegen.provider_profile` value per smoke run. The
recommended remote code-generation profile is `coding`, backed by Gemini 3.5
Flash. The additional remote smoke profiles are `fast` for OpenAI,
`anthropic_fast` for Anthropic, and `openrouter_fast` for OpenRouter.

For local Ollama fallback smoke work, use `dynamic_codegen.provider_profile
coding_local`, pull `qwen2.5-coder:7b` explicitly, and make sure
`OLLAMA_BASE_URL` is set in `.env` when it differs from
`http://localhost:11434/v1`. That environment override is scoped to local
Ollama profiles and must not override the real OpenAI provider endpoint:

```sh
ollama pull qwen2.5-coder:7b
mix allbert.settings set dynamic_codegen.provider_profile coding_local
```

Gemini credentials use the Settings Central secret reference
`secret://providers/gemini/api_key`. For disposable smoke runs, ReqLLM can also
read `GOOGLE_API_KEY` or `GEMINI_API_KEY` from the shell or `.env`; OpenRouter
uses `secret://providers/openrouter/api_key` or `OPENROUTER_API_KEY`.

OpenAI-backed profiles must keep `model_profiles.*.max_tokens` at `16` or
higher because the OpenAI Responses API rejects lower `max_output_tokens`
values. Shipped OpenAI profiles are well above that minimum, and Settings
Central rejects smaller OpenAI profile values.

The workflow still fails closed if the provider profile cannot resolve, the
provider is disabled, a required credential is missing, the sandbox doctor is
not green, or the live loader switch is false.

Delegated writes are closed by default. Enable them only for a smoke that needs
them, and only with the reviewed facade names you intend to allow:

```sh
mix allbert.settings set dynamic_codegen.allowed_action_permissions read_only,memory_write,external_network
mix allbert.settings set dynamic_codegen.allowed_facades append_memory,external_network_request
```

## Request A Draft

The advisory producer is a guarded source generator. It creates a
producer-neutral draft for an explicit operator or objective request, calls the
configured model profile through Jido.AI structured generation, writes reviewed
action source plus a focused test, and records provider/budget diagnostics.
Failed validation or sandbox evidence can drive Repair until the configured
iteration and provider budgets are exhausted. The draft is still untrusted until
the sandbox gate, trusted validation, and operator confirmation pass.
The request action is controlled by `permissions.dynamic_codegen_request`
(default `allowed`), separate from historical `permissions.skill_write`.

```sh
mix allbert.dynamic drafts request weather_summary "Create a read-only weather summary action"
```

For delegated memory or network actions, the generated action must declare the
matching permission and call the reviewed facade through a literal
`AllbertAssist.DynamicPlugins.Delegate.run/3` facade name:

```sh
mix allbert.dynamic drafts request delegated_memory "Create a memory_write action that appends operator-reviewed memory by delegating to append_memory"
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
  undeclared modules, permission/body mismatch, non-literal delegate facade
  names, non-allowlisted facades, and collision checks.

The draft root is:

```text
<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/
```

The integrated root is:

```text
<ALLBERT_HOME>/dynamic_plugins/integrated/<slug>/<revision>/
```

The lifecycle audit file is:

```text
<ALLBERT_HOME>/dynamic_plugins/audit/YYYY-MM.md
```

Ordinary plugin discovery must not scan either root.

## Confirm Integration

Integration is requested through the registered `integrate_dynamic_draft`
action. When it needs trust, it creates a Security Central confirmation for
hot-loading the reviewed source. Approve only from high-trust operator surfaces
allowed by
`dynamic_codegen.integration_approval_surfaces`:

```sh
mix allbert.dynamic drafts integrate <slug>
mix allbert.confirmations list
mix allbert.confirmations show <confirmation-id>
mix allbert.confirmations approve <confirmation-id> --reason "reviewed v0.37 gate evidence"
```

The integration action denies approval from Telegram, email, or cross-channel
surfaces even when global confirmation settings would otherwise permit them.
That surface restriction is intentionally only for integration and rollback. If
an integrated dynamic action delegates to `append_memory` or
`external_network_request`, the reviewed facade creates and resolves any
per-invocation confirmation through its normal Security Central channel policy.
The confirmation records dynamic delegate provenance in runner metadata for
audit, but it does not inherit the integration approval-surface restriction.

After approval, inspect the registration state:

```sh
mix allbert.dynamic integrations show <slug>
mix allbert.security review --recent --limit 25
```

Also inspect the dynamic lifecycle audit for compile/load/register events:

```sh
cat "$ALLBERT_HOME/dynamic_plugins/audit/$(date -u +%Y-%m).md"
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

## Discard

Discard an untrusted, failed, or already rolled-back draft when you no longer
want it to be eligible for gate or integration:

```sh
mix allbert.dynamic drafts discard <slug>
mix allbert.dynamic drafts show <slug>
```

Discard is terminal for that draft revision. Integrated artifacts must be rolled
back first, because discard never removes live authority by itself. The action
uses `permissions.dynamic_codegen_discard` / `:dynamic_codegen_discard`,
defaults to `allowed`, and does not require confirmation for any non-integrated
tier. Discarding a `:gate_passed` draft can irreversibly remove reviewed source,
sandbox reports, and gate evidence; operators who want to preserve that work
should roll it forward or archive the draft root before discarding.

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
integrated source. It uses the `:settings_write` permission and does not require
confirmation because it only reduces live dynamic authority.

## Manual Verification Checklist

- Workflow is disabled by default.
- Sandbox doctor failure blocks trial, gate, and integration.
- Missing or unresolved provider profile blocks generation.
- Missing `.env`/Settings credentials for a required remote provider block
  generation without printing secrets.
- Draft metadata lives under Allbert Home, not Settings Central.
- Gate pass without confirmation cannot integrate.
- Confirmation from a disallowed surface is denied and audited.
- Tampering with reviewed source after the gate blocks integration.
- A dynamic action can run only after registration through the overlay.
- Delegated writes require both an enabled generated permission and a literal
  facade name present in `dynamic_codegen.allowed_facades`.
- Delegated facade calls create or complete the same confirmations the reviewed
  facade would create outside dynamic code.
- `dynamic_codegen.live_loader_enabled=false` removes or blocks live authority.
- Rollback removes dynamic action authority and leaves inspectable metadata.
- Integration, denial, rollback, disablement, and reconcile decisions appear in
  the dynamic lifecycle audit.
