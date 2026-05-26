# Dynamic Plugin Drafts Developer Contract

Status: v0.37 implementation contract.

This guide defines the implementation shape for dynamic capability drafts. It is
the developer companion to `docs/operator/dynamic-capability-integration.md` and
the request flow in `docs/plans/v0.37-request-flow.md`.

## Roots

Drafts are inert file-backed data under Allbert Home:

```text
<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/
  metadata.yaml
  manifest.yaml
  source/lib/action.ex
  source/test/action_test.exs
  reports/
  diagnostics/
```

Integrated artifacts are reviewed source snapshots:

```text
<ALLBERT_HOME>/dynamic_plugins/integrated/<slug>/<revision>/
  metadata.yaml
  manifest.yaml
  source/
  reports/
```

Lifecycle audit records are append-only markdown:

```text
<ALLBERT_HOME>/dynamic_plugins/audit/YYYY-MM.md
```

`AllbertAssist.Plugin.Discovery` and ordinary app/plugin bootstrap must not scan
either root. Registration authority belongs only to
`AllbertAssist.DynamicPlugins.Loader`.

## Metadata

`metadata.yaml` is inspectable state, not a trust anchor. Security Central
confirmation records, current source hashes, gate reports, and loader policy are
rechecked before authority is granted.

Required shape:

```yaml
schema_version: 1
slug: weather_summary
revision: rev_2026_05_25_001
tier: draft
producer: codegen_llm
provider_profile: local
target_shapes: [action]
source_hashes:
  source/lib/action.ex: sha256:...
  source/test/action_test.exs: sha256:...
compiled_paths:
  - apps/allbert_assist/lib/allbert_assist/dynamic_plugins/generated/weather_summary/action.ex
  - apps/allbert_assist/test/allbert_assist/dynamic_plugins/generated/weather_summary/action_test.exs
scan_paths:
  - source/lib/action.ex
  - source/test/action_test.exs
budget:
  provider_calls_used: 1
  provider_usage_units_used: 1234
gate:
  status: not_run
  sandbox_report_id: null
static_validation:
  status: not_run
confirmations:
  integration_id: null
  rollback_id: null
diagnostics: []
repair_history: []
timestamps:
  created_at: "2026-05-25T00:00:00Z"
  updated_at: "2026-05-25T00:00:00Z"
```

Legal tiers are `draft`, `sandbox_compiled`, `sandbox_trialed`, `gate_passed`,
`integrated`, `rolled_back`, and `discarded`.

Repair creates a new revision. It must not mutate the evidence for an older
revision.

## Capability Gaps And Codegen Producer

`AllbertAssist.DynamicPlugins.request_draft/3` is the producer-neutral entrypoint
for v0.37 capability gaps. It routes through
`AllbertAssist.DynamicPlugins.Codegen.Agent`, a `JidoBacked` coordinator, and
then through `Codegen.Producer`. Durable authority still lives in draft metadata
and objective events; the agent keeps only rebuildable diagnostics.

The request vocabulary is normalized by
`AllbertAssist.DynamicPlugins.Codegen.CapabilityGap`:

- `slug`
- `summary` or `requested_capability`
- `objective_id` and optional `step_id`
- `source` (`operator` or `objective` for explicit generation)
- `target_shapes`
- `confidence`
- `provider_calls_requested` and `provider_usage_units_requested`

The v0.37.3 producer contract is a deliberately bounded source generator. It
requires:

- `dynamic_codegen.enabled=true`
- a resolvable `dynamic_codegen.provider_profile`
- an enabled provider profile, with any required credential configured
- target shapes allowed by `dynamic_codegen.allowed_targets`
- requested generated permissions allowed by
  `dynamic_codegen.allowed_action_permissions`
- for delegated writes, literal facade names allowed by
  `dynamic_codegen.allowed_facades`
- provider-call and usage requests within
  `dynamic_codegen.max_provider_calls_per_gap` and
  `dynamic_codegen.max_provider_usage_units_per_gap`
- an explicit operator/objective source

It writes a `draft` tier metadata record with `producer: codegen_llm`,
`gate.status: not_run`, source/test hashes, compile-visible source/test paths,
scan paths, diagnostics, repair history, and consumed provider budget. It calls
the configured Jido.AI structured-generation provider through bounded
Planner/Author/TrialAuthor/Critic role packets to author one action draft, and
invokes Repair only when deterministic evidence or Critic requests repair. The
action can be pure `:read_only`, or it can declare `:memory_write` /
`:external_network` only when its effect path delegates through a reviewed
facade. It does not trust model output or integrate live code. Sandbox/gate
execution remains an explicit evidence step. If an objective id is present, it
records an `observed` objective event whose payload stage is
`dynamic_codegen_draft_requested`.
The registered request action uses `:dynamic_codegen_request` and
`permissions.dynamic_codegen_request`, not `:skill_write`, so skill scaffold
policy and LLM-backed draft generation can be audited and disabled separately.

Operator-facing wrappers:

```sh
mix allbert.dynamic drafts request <slug> <summary...>
```

```elixir
AllbertAssist.Actions.Runner.run("request_dynamic_draft", params, context)
```

Low-confidence intent ranking and advisory/agent output may suggest a capability
gap to an operator, but they cannot start generation through this entrypoint.

## LLM Generation Contract

`AllbertAssist.DynamicPlugins.Codegen.LLM` is the injectable provider boundary.
Production calls `Jido.AI.generate_object/3` through role-specific JSON schemas.
Author requires:

- `description`
- `source`
- `test_source`

Generated packets may also include `action_name`, `notes`, and `usage_units`.
Planner emits the generation spec and acceptance criteria, TrialAuthor emits
focused tests, Critic emits advisory findings over static and sandbox evidence,
and Repair emits a new full source/test packet for a new revision when repair is
needed. The production adapter records token usage from the Jido/ReqLLM
response when available; deterministic tests inject a fake provider with the
same `generate_role/5` callback.

The producer records explicit role packets in `manifest.yaml` and
`repair_history`:

- `planner`
- `author`
- `trial_author`
- `critic`
- `repair` (only when repair is requested)

These roles are model-backed but advisory. The workflow is bounded by the
settable whole-workflow provider-call cap
`dynamic_codegen.max_provider_calls_per_gap`, provider-usage budget,
`dynamic_codegen.max_repair_iterations`, wall-clock timeout, and
repeated-identical-failure detection. Critic output can request repair, but it
cannot trust a draft, advance tiers, or authorize integration.

Generated source must use placeholders rather than fixed names:

- `{{MODULE}}`
- `{{TEST_MODULE}}`
- `{{ACTION_NAME}}`
- `{{SLUG}}`

`Codegen.Targets.Action` stamps those placeholders into the reserved generated
namespace and records deterministic compile paths. The producer records
`producer: codegen_llm`; older `codegen_scaffold` metadata remains historical
only.

## Generated Namespace

Generated modules must live under:

```elixir
AllbertAssist.DynamicPlugins.Generated.<Slug>
```

The shipped loader accepts reviewed action modules only. It rejects:

- core/static module replacement;
- undeclared modules;
- generated apps, panels, settings fragments, memory namespaces, objective
  wiring, route pages, and child processes;
- generated protocols;
- router edits or route-page integration;
- migrations and dependency changes;
- NIFs, ports, package-manager hooks, and application env mutation.

`manifest.yaml` must list every generated module and action. Manifest
declarations and parsed `defmodule` forms reconcile in both directions. Future
app, surface, settings-fragment, memory-namespace, objective-wiring, or child
target shapes require their own trusted validators before they can become live.

## Staging And Sandbox Gate

The durable draft root is not a compile root. Before sandbox trial or gate,
v0.37 builds a disposable project-shaped staging tree and materializes generated
files into compile-visible paths:

```text
staging/
  mix.exs
  apps/allbert_assist/lib/allbert_assist/dynamic_plugins/generated/<slug>/
  apps/allbert_assist/test/allbert_assist/dynamic_plugins/generated/<slug>/
```

The staged tree includes the root Mix files, formatter config, Credo config,
Dialyzer ignore config, root config, app source, and reviewed source-tree plugin
inputs needed by the real umbrella warning gate.

`Sandbox.SourcePolicy.scan/2` must scan the same generated bytes that the gate
will compile. Compiled-path hashes and scanned-path hashes must match. A gate
report from unscanned bytes, or from scanned bytes that are not compile-visible,
is invalid evidence.

M2 implements this through `AllbertAssist.DynamicPlugins.Staging` and
`AllbertAssist.DynamicPlugins.SandboxBridge`. `manifest.yaml` declares each
generated source/test file with `source_path` under the draft root and
`compiled_path` under the staged project:

```yaml
files:
  - source_path: source/lib/action.ex
    compiled_path: apps/allbert_assist/lib/allbert_assist/dynamic_plugins/generated/weather_summary/action.ex
tests:
  - source_path: source/test/action_test.exs
    compiled_path: apps/allbert_assist/test/allbert_assist/dynamic_plugins/generated/weather_summary/action_test.exs
focused_test_paths:
  - apps/allbert_assist/test/allbert_assist/dynamic_plugins/generated/weather_summary/action_test.exs
```

`source_hashes`, `scan_paths`, `compiled_paths`, and the manifest must describe
the same file set. Missing hashes fail as unscanned compile paths; extra scanned
hashes fail as scanned-but-not-compiled evidence. The bridge copies v0.36 sandbox
reports back into the draft `reports/` directory and updates the evidence tier;
it still does not load code or register runtime authority.

Generated tests are evidence only. They do not replace trusted validation,
operator review, Security Central confirmation, or the generated-permission
ceiling.

## Trusted Validator

`AllbertAssist.DynamicPlugins.TrustedValidator` parses reviewed generated source
without executing it and walks the AST with default-deny semantics.

Allowed forms in v0.37.3:

- generated-namespace `defmodule`;
- `def` and `defp`;
- inert literal module attributes from a small allowlist;
- `alias`, `require`, `import`, and `use` for reviewed allowlisted targets only;
- `use AllbertAssist.Action`;
- normal pure action logic, including arithmetic, comparisons, boolean
  operators, string concatenation/interpolation, `case`/`cond`/`if`/`with`/`for`,
  anonymous functions/captures whose bodies validate, and a curated per-function
  allowlist from pure standard modules such as `Enum`, `String`, `Map`,
  `Keyword`, `List`, `Integer`, `Float`, `Tuple`, `Date`, `Time`, and
  `DateTime`;
- exact calls to `AllbertAssist.DynamicPlugins.Delegate.run/3` for delegated
  writes, with a binary string literal facade name.

All macro options, action DSL options, schema entries, tags, attributes, and
manifest values must be inert literals.

Denied forms include:

- top-level expression execution;
- `@on_load` and custom `@compile` hooks;
- dynamic module construction;
- `Code.eval_*`, `Code.compile_*`, and `Code.require_*`;
- `apply/3` dynamic dispatch;
- HEEx sigils, LiveViews, Phoenix components, and route modules;
- application env mutation, migrations, dependencies, package managers, NIFs,
  ports, and shell/process execution.

The shipped validator scans call targets in action `run/2` and helpers. Future
app callbacks, surface data builders, and child callbacks must use the same
rules before those target shapes can become live. It allows local generated
calls, an explicit allowlist of side-effect-free Elixir helpers, and the
delegation shim only. Direct calls to Settings writes, secrets, confirmations,
Resource grants, Repo writes, sandbox actions, integration/rollback/disable
actions, distributed Erlang, shell/process runners, package/skill execution,
and trust control are denied.

## Permission Ceiling

Generated actions are `resumable?: false`.

Allowed by the shipped v0.37.3 generated-action ceiling:

- `:read_only`
- `:memory_write`
- `:external_network`

The default Settings Central value remains `["read_only"]`. Operators must
enable `memory_write` or `external_network` in
`dynamic_codegen.allowed_action_permissions` and enable the matching reviewed
facade in `dynamic_codegen.allowed_facades` before either can validate.
`append_memory` carries `:memory_write`; `external_network_request` carries
`:external_network`.

Deferred until future validators and delegation ceilings exist:

- `:objective_write`
- `:workspace_canvas_write`

Hard-denied:

- host execution;
- package install;
- skill import or skill script execution;
- sandbox trial/gate;
- secret read/write;
- confirmation decision;
- Security Central trust control;
- integration, rollback, or disablement;
- direct Settings mutation;
- Resource-grant mutation.

Declared permission, confirmation metadata, response action metadata, body call
targets, and delegated facade permission must agree. Mismatch is denial.
Generated actions remain `resumable?: false`; facade-owned confirmations keep
the reviewed facade's ordinary resume path.

## Loader Lifecycle

`AllbertAssist.DynamicPlugins.Loader.integrate/2` currently integrates
reviewed action artifacts only. Generated apps, panels, settings fragments,
memory namespaces, objective wiring, route pages, and child processes are
explicitly rejected in v0.37 until they have their own trusted validators and
registration paths.

The loader must:

1. verify settings allow live loading;
2. verify tier is `gate_passed`;
3. verify the integration confirmation and allowed resolver surface;
4. verify source hashes and gate evidence;
5. rerun trusted validation over reviewed source;
6. copy reviewed source to the integrated root;
7. compile reviewed source in core;
8. register action overlay entries;
9. mark the revision `integrated`;
10. audit each step under `<ALLBERT_HOME>/dynamic_plugins/audit/` and emit
    dynamic codegen lifecycle signals.

The attempt is all-or-nothing. If any step fails before stable integration, the
loader unregisters action/modules from the attempt, removes unstable integration
root data, and leaves the draft at `gate_passed` with bounded diagnostics.

## Actions Overlay

`AllbertAssist.DynamicPlugins.ActionsOverlay` is runtime mutable and
state-bearing. It is a plain `GenServer` because it stores reviewed registration
entries and diagnostics; there is no useful state-machine successor beyond
loader-owned calls.

The overlay denies collisions with:

- static core action names;
- source-tree plugin/app action names;
- existing dynamic action names;
- action modules already registered elsewhere.

`AllbertAssist.Actions.Registry` merges overlay entries through existing public
functions: `modules/0`, `agent_modules/0`, `capabilities/0`,
`agent_capabilities/0`, `internal_capabilities/0`, `resolve/1`,
`capability/1`, `registered_module?/1`, `capabilities_for_app/1`, and
`diagnostics/0`.

Precedence is static actions, reviewed source-tree plugin/app actions, then
dynamic actions. Collision is denial, not shadowing.

## Unsupported Live Targets

Generated apps, panels, settings fragments, memory namespaces, objective
wiring, route pages, and children are not live-loaded by the v0.37
implementation. Drafts may record those future target shapes for planning, but
the trusted validator rejects them before core compilation. Future child support
must keep the documented state-only constraint: callbacks pass the same
call-target validator and must not start autonomous timers, network calls,
shell/package/script execution, durable goal loops, or protected subsystem
writes.

## Reconciliation And Disablement

On boot, the loader may re-register only integrated revisions whose metadata,
source hash, gate evidence, Security Central confirmation, current settings, and
current policy all still match.

If `dynamic_codegen.live_loader_enabled=false`, reconciliation must not register
dynamic authority. The registered `disable_dynamic_live_loader` action turns the
switch off and clears the live action overlay without deleting source.

Both reconcile keep/deny decisions and emergency disablement are audited in the
dynamic plugin audit file.

## Rollback And Upgrade

Rollback requires operator confirmation and removes dynamic action authority.

## Discard

`discard_dynamic_draft` and `mix allbert.dynamic drafts discard <slug>` are the
operator-facing discard surfaces. They call the file-backed draft store's
terminal `:discarded` transition for non-integrated or already rolled-back
drafts. Integrated artifacts must roll back before discard. Discard is a
safety-reducing cleanup path: it cannot register actions, cannot preserve live
authority, and records the same dynamic lifecycle audit/signal event as the
store helper.
Module purge/delete is best effort and audited.

Same-name upgrades require rollback before integrating a new revision. v0.37
does not support in-place mutation or atomic supersede.
