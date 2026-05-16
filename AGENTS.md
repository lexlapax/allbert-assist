# AGENTS.md

This repository is Allbert: an Elixir/OTP assistant runtime built with Phoenix
and Jido. Phoenix LiveView is one operator/channel interface, not the center of
the system. The center is a signal-driven runtime, Jido agents and actions,
Security Central, markdown-first memory, Settings Central, and Allbert Home.

## Start Here

Before coding, read:

1. `DEVELOPMENT.md`
2. `docs/plans/roadmap.md`
3. The active milestone plan in `docs/plans/`
4. The matching request-flow document, when one exists
5. Relevant ADRs in `docs/adr/`

For v0.03 skill substrate regression work, read
`docs/plans/v0.03-plan.md`, `docs/plans/v0.03-request-flow.md`, and
`docs/adr/0003-skill-manifests-as-capability-contracts.md`.

For v0.04 runtime convergence regression or boundary-adjacent work, read
`docs/plans/v0.04-plan.md`,
`docs/plans/v0.04-request-flow.md`,
`docs/adr/0001-signal-first-jido-runtime.md`, and
`docs/adr/0007-jido-native-internal-runtime-boundaries.md` before changing
runtime-facing action, signal, agent, CLI, LiveView, settings, skills, memory,
trace, or future security boundaries.

For v0.05 Security Central work, read `docs/plans/v0.05-plan.md`,
`docs/plans/v0.05-request-flow.md`, and
`docs/adr/0006-security-central.md`, and
`docs/adr/0007-jido-native-internal-runtime-boundaries.md` before changing
security evaluation, permission policy, redaction, risk, trust, or audit
behavior.

For v0.06 skill-backed execution work, read `docs/plans/v0.06-plan.md`,
`docs/plans/v0.06-request-flow.md`, `docs/plans/v0.03-plan.md`,
`docs/plans/v0.03-request-flow.md`,
`docs/adr/0003-skill-manifests-as-capability-contracts.md`, and
`docs/adr/0006-security-central.md`, and
`docs/adr/0007-jido-native-internal-runtime-boundaries.md`.

For v0.07 confirmation workflow regression work, read `docs/plans/v0.07-plan.md`,
`docs/plans/v0.07-request-flow.md`,
`docs/adr/0001-signal-first-jido-runtime.md`,
`docs/adr/0006-security-central.md`,
`docs/adr/0007-jido-native-internal-runtime-boundaries.md`, and
`docs/adr/0008-durable-confirmation-requests.md` before changing
confirmation queues, approval/denial behavior, action resumption, traces,
audits, CLI, LiveView, or future execution boundaries.

For v0.08 local execution sandbox regression work, read
`docs/plans/v0.08-plan.md`, `docs/plans/v0.08-request-flow.md`,
`docs/plans/v0.07-plan.md`, `docs/plans/v0.07-request-flow.md`,
`docs/adr/0001-signal-first-jido-runtime.md`,
`docs/adr/0006-security-central.md`,
`docs/adr/0007-jido-native-internal-runtime-boundaries.md`,
`docs/adr/0008-durable-confirmation-requests.md`, and
`docs/adr/0009-local-execution-sandbox-levels.md` before changing command
planning, confirmed shell execution, sandbox policy, confirmation resume
semantics, traces, audits, CLI, or LiveView behavior. v0.08 implements Level 1
local policy sandboxing only; container, remote, and microVM isolation are
future adapter work.

For active v0.09 skill script runner work, read `docs/plans/v0.09-plan.md`,
`docs/plans/v0.09-request-flow.md`, `docs/plans/v0.03-plan.md`,
`docs/plans/v0.03-request-flow.md`, `docs/plans/v0.06-plan.md`,
`docs/plans/v0.06-request-flow.md`, `docs/plans/v0.08-plan.md`,
`docs/plans/v0.08-request-flow.md`,
`docs/adr/0003-skill-manifests-as-capability-contracts.md`,
`docs/adr/0006-security-central.md`,
`docs/adr/0007-jido-native-internal-runtime-boundaries.md`,
`docs/adr/0008-durable-confirmation-requests.md`,
`docs/adr/0009-local-execution-sandbox-levels.md`, and
`docs/adr/0010-resource-gated-skill-script-execution.md` before changing
skill script execution, skill resource inventory, skill trust, script
permissions, script runner policy, confirmations, traces, audits, CLI, or
LiveView behavior.

For active v0.10 external capability adapter work, read
`docs/plans/v0.10-plan.md`, `docs/plans/v0.10-request-flow.md`,
`docs/plans/v0.07-request-flow.md`, `docs/plans/v0.08-request-flow.md`,
`docs/plans/v0.09-request-flow.md`,
`docs/adr/0006-security-central.md`,
`docs/adr/0008-durable-confirmation-requests.md`,
`docs/adr/0009-local-execution-sandbox-levels.md`,
`docs/adr/0010-resource-gated-skill-script-execution.md`, and
`docs/adr/0011-confirmed-external-capability-adapters.md`, and
`docs/adr/0012-resource-access-security-posture.md` before changing external
HTTP/service calls, package installs, online skill search/audit/import, Req
policy, source profiles, package-manager profiles, resource references,
remembered grants, confirmation resume semantics, traces, audits, CLI, or
LiveView behavior.

For active v0.11 execution-aware intent, Approval Handoff, or Resource Access
Security Posture work, read `docs/plans/v0.11-plan.md`,
`docs/plans/v0.11-request-flow.md`,
`docs/plans/v0.10-plan.md`, `docs/plans/v0.10-request-flow.md`,
`docs/plans/v0.07-request-flow.md`, `docs/plans/v0.08-request-flow.md`,
`docs/plans/v0.09-request-flow.md`,
`docs/adr/0006-security-central.md`,
`docs/adr/0008-durable-confirmation-requests.md`,
`docs/adr/0009-local-execution-sandbox-levels.md`,
`docs/adr/0010-resource-gated-skill-script-execution.md`,
`docs/adr/0011-confirmed-external-capability-adapters.md`,
`docs/adr/0012-resource-access-security-posture.md`, and
`docs/adr/0013-uri-first-resource-identity.md` before changing intent
decisions, approval handoff data, channel-native approval UX, resource access
operation classes, remembered resource grants, URL summarization, document
inspection, direct skill URL import, local skill directory import, traces,
audits, CLI, or LiveView behavior.

For v0.12 local workspace identity and conversation history work, read
`docs/plans/v0.12-plan.md`, `docs/plans/v0.12-request-flow.md`,
`docs/plans/allbert-jido-vision.md`, and
`docs/adr/0014-local-workspace-identity.md` before changing runtime request
maps, conversation history schemas, `user_id` or `thread_id` propagation,
traces, CLI thread tasks, or identity aliasing between `operator_id` and
`user_id`.

For v0.13 scheduled jobs work, read `docs/plans/v0.13-plan.md`,
`docs/plans/v0.13-request-flow.md`, `docs/plans/v0.11-request-flow.md`,
`docs/plans/v0.12-request-flow.md`, `docs/plans/allbert-jido-vision.md`,
`docs/adr/0008-durable-confirmation-requests.md`,
`docs/adr/0012-resource-access-security-posture.md`, and
`docs/adr/0014-local-workspace-identity.md` before changing job storage,
scheduler supervision, job CLI/LiveView surfaces, job-origin confirmation
metadata, schedule settings, or background runtime/action execution.

For v0.14 session scratchpad work, read `docs/plans/v0.14-plan.md`,
`docs/plans/v0.14-request-flow.md`, `docs/plans/allbert-jido-vision.md`, and
`docs/adr/0014-local-workspace-identity.md` before changing ETS session state,
`session_id` handling, `active_app`, TTL behavior, traces, or scratchpad
supervision.

For v0.15 app contract work, read `docs/plans/v0.15-plan.md`,
`docs/plans/v0.15-request-flow.md`, `docs/plans/allbert-jido-vision.md`, and
`docs/adr/0015-allbert-app-contract-and-surface-dsl.md` before changing
`AllbertAssist.App`, `AllbertAssist.App.Registry`, app-level action or skill
registration, or workspace navigation metadata.

For v0.16 additional channel work, read `docs/plans/v0.16-plan.md`,
`docs/plans/v0.16-request-flow.md`, `docs/plans/allbert-jido-vision.md`,
`docs/adr/0004-domain-settings-engine.md`,
`docs/adr/0007-jido-native-internal-runtime-boundaries.md`,
`docs/adr/0008-durable-confirmation-requests.md`,
`docs/adr/0012-resource-access-security-posture.md`,
`docs/adr/0014-local-workspace-identity.md`, and
`docs/adr/0016-channel-adapter-boundary-and-identity-mapping.md` before
changing channel adapters, external identity mapping, channel settings or
secrets, Telegram transport, channel events, callback approvals, channel
rendering, or runtime channel metadata. v0.16 channels are delivery adapters
around the runtime and registered actions; they must not own intent,
confirmation storage, resource access policy, memory, or execution.

For v0.17 plugin contract work, read `docs/plans/v0.17-plan.md`,
`docs/plans/v0.17-request-flow.md`, `docs/plans/allbert-jido-vision.md`,
`docs/adr/0017-allbert-plugin-contract.md`,
`docs/adr/0015-allbert-app-contract-and-surface-dsl.md`, and
`docs/adr/0016-channel-adapter-boundary-and-identity-mapping.md` before
changing plugin discovery, plugin paths, plugin settings, plugin-contributed
apps/actions/skills/settings/children, channel registration, shipped
Telegram/email source-tree plugin wrappers, or plugin diagnostics. v0.17 plugins are
package/discovery contracts, not authority; they must not load arbitrary code
from `<ALLBERT_HOME>/plugins`, grant trust, grant permissions, bypass
confirmations, execute package managers during discovery, add a parallel
channel registry, or automatically compile arbitrary `./plugins/*/lib` folders.
Plugin-owned child specs run under the plugin child supervisor; channel
adapters still start from registered descriptors under
`AllbertAssist.Channels.Supervisor`. Telegram and email move into
`./plugins/allbert.telegram` and `./plugins/allbert.email` as shipped
source-tree plugins.

For v0.18 app contract and surface DSL regression work, read `docs/plans/v0.18-plan.md`,
`docs/plans/v0.18-request-flow.md`, `docs/plans/v0.15-plan.md`,
`docs/plans/v0.15-request-flow.md`,
`docs/plans/allbert-jido-vision.md`, and
`docs/adr/0015-allbert-app-contract-and-surface-dsl.md` before changing
`AllbertAssist.App.SurfaceProvider`, `AllbertAssist.Surface`, full app
callbacks, surface validation, workspace navigation, or canvas component
catalogs.

For v0.19 cross-surface intent enrichment regression work, read
`docs/plans/v0.19-plan.md`, `docs/plans/v0.19-request-flow.md`,
`docs/plans/v0.11-plan.md`,
`docs/plans/v0.11-request-flow.md`, `docs/plans/v0.18-plan.md`,
`docs/plans/v0.18-request-flow.md`, `docs/plans/allbert-jido-vision.md`,
`docs/adr/0012-resource-access-security-posture.md`,
`docs/adr/0014-local-workspace-identity.md`,
`docs/adr/0015-allbert-app-contract-and-surface-dsl.md`,
`docs/adr/0017-allbert-plugin-contract.md`, and
`docs/adr/0019-cross-surface-intent-enrichment.md` before changing intent
candidate ranking, app/surface routing inputs, model-assisted classification,
classifier prompt content, or intent eval fixtures. v0.19 consumes app/surface
metadata; it must not add new execution powers, treat plugin provenance as
authority, treat `active_app` as authorization, or make model output
authoritative over the collected candidate set.

For v0.24 agentic workspace surface and ephemeral UI work, read
`docs/plans/v0.24-plan.md`, `docs/plans/v0.25-plan.md`,
`docs/plans/v0.18-plan.md`, `docs/plans/allbert-jido-vision.md`, and
`docs/adr/0015-allbert-app-contract-and-surface-dsl.md` before changing the
workspace shell lifecycle, canvas persistence, ephemeral surface scoping and
discard, surface validation at render time, signal-to-render pipeline, or
workspace navigation behavior. v0.24 requires v0.18 app/surface contract, v0.19
intent enrichment, v0.21 memory review, v0.22 Python bridge, and v0.23 Native
Jido agents. v0.25 StockSage LiveViews and v0.26 security hardening follow.

For StockSage workspace app work, read the active StockSage milestone plan
(`docs/plans/v0.20-plan.md`, `docs/plans/v0.22-plan.md`,
`docs/plans/v0.23-plan.md`, `docs/plans/v0.25-plan.md`,
`docs/plans/v0.27-plan.md`, or `docs/plans/v0.28-plan.md`),
`docs/plans/allbert-jido-vision.md`,
`docs/adr/0006-security-central.md`,
`docs/adr/0017-allbert-plugin-contract.md`,
`docs/adr/0014-local-workspace-identity.md`, and
`docs/adr/0015-allbert-app-contract-and-surface-dsl.md` before changing
StockSage agents, actions, domain records, the Python bridge, StockSage
LiveViews, canvas components, or the StockSage skill pack. For v0.20 also read
`docs/plans/v0.20-request-flow.md` and
`docs/adr/0018-stocksage-local-domain-app.md`. For v0.22 also read
`docs/plans/v0.22-request-flow.md` and
`docs/adr/0020-stocksage-python-bridge-protocol.md` before changing
`StockSage.TraderBridge`, `StockSage.Bridge.Protocol`, `bridge.py`,
`StockSage.Actions.RunAnalysis`, `:stocksage_analyze` permission policy,
bridge protocol, bridge supervision, or result persistence. StockSage enters
as a shipped source-tree plugin app after v0.17; v0.20 uses `./plugins/stocksage`,
`AllbertAssist.Repo`, and `stocksage_*` tables, not `apps/stocksage`,
`apps/stocksage_web`, or a separate `StockSage.Repo`. v0.20 read-by-id paths
must require `user_id`; `:stocksage_write` is scoped to local StockSage domain
writes and must not authorize financial API calls or analysis execution.
v0.22 adds `:stocksage_analyze` as the distinct permission class for bridge
execution; all bridge code lives under `./plugins/stocksage/` and Allbert
core does not import bridge internals. The `:stocksage_analyze` safety floor
is `:needs_confirmation`; no setting can lower it to `:allowed`.

For v0.29 plugin/app generator work, read `docs/plans/v0.29-plan.md`,
`docs/plans/v0.18-plan.md`, `docs/plans/v0.20-plan.md`,
`docs/plans/v0.24-plan.md`, `docs/plans/v0.25-plan.md`,
`docs/plans/v0.27-plan.md`, `docs/plans/v0.28-plan.md`, and
`docs/adr/0017-allbert-plugin-contract.md`, and
`docs/adr/0015-allbert-app-contract-and-surface-dsl.md` before changing
`mix allbert.gen.plugin`, `mix allbert.gen.app`, generated plugin/app
structure, generated skill or action inertness, or `mix allbert.publish_skills`.
The generator encodes the shape proven by v0.20 StockSage plugin/app, v0.25
StockSage SurfaceProvider LiveViews, v0.27 memory namespace completion, and
v0.28 canvas integration.
The generator must not grant automatic trust, enable generated skills, load
runtime modules from arbitrary folders, or publish externally without explicit
operator action.

## Non-Negotiables

- Preserve user data. Do not delete or rewrite memory, traces, settings,
  secrets, databases, skill folders, or user-created files unless explicitly
  asked.
- Keep code warning-free: no compiler warnings, no HEEx/parser warnings, no
  unused aliases/imports, and no lexical tracker warnings.
- Use Context7 MCP for fresh docs whenever implementation depends on a
  library, framework, SDK, API, CLI, cloud service, or provider. If Context7 is
  unavailable, use official docs or source and say so.
- All user/operator-supplied configuration belongs in Settings Central.
- All durable local runtime data should derive from Allbert Home:
  `ALLBERT_HOME`, alias `ALLBERT_HOME_DIR`, default `~/.allbert`.
- Tests and CI must use a temporary Allbert home or temp-specific roots; never
  write to a real user's `~/.allbert`.
- User-supplied secrets, including API keys, must be encrypted at rest and
  redacted in CLI output, LiveView, traces, audits, logs, and tests.
- Runtime-facing, effectful, security-relevant, or observable domain behavior
  belongs behind signals, internal agents or runtime routers, and registered
  Jido actions. Pure parsing, validation, schema, formatting, and storage
  helpers may remain plain Elixir behind those boundaries.
- Runtime-facing action invocation should resolve through
  `AllbertAssist.Actions.Registry` and execute through
  `AllbertAssist.Actions.Runner.run/3` so lifecycle signals, runner metadata,
  permission decisions, redaction, and future Security Central behavior stay
  consistent.
- Security decisions and permission checks belong at the action boundary.
  Skills, model output, and YAML declarations never grant permission by
  themselves.
- v0.03 skills are compatibility/importability context only. v0.04 converges
  runtime boundaries without new execution powers. v0.05 adds Security Central
  but no new execution powers. v0.06 action-backed skills must call registered
  Elixir/Jido actions through the action runner and Security Central. v0.07
  adds durable confirmation requests and approval/denial workflow, but approval
  is not a generic capability grant and must not bypass Security Central safety
  floors. Confirmation records should preserve origin and resolver channel
  context rather than becoming CLI-only or LiveView-only prompts. v0.08 adds
  confirmed shell execution through Level 1 host policy controls. v0.09 skill
  scripts may run only as trusted, inventoried resources through
  `run_skill_script`, Security Central, confirmation, digest re-check, and
  trace/audit boundaries. v0.10 external services, package installs, and online
  skill imports may run only through registered actions, `Req`, Settings
  Central policy and secrets, Security Central, durable confirmation,
  target-specific re-checks, redaction, and trace/audit records. v0.11
  Resource Access Security Posture must keep URL summaries, document
  inspection, direct skill URL import, local skill directory import, local path
  access, trusted skill script execution, and online source consumers behind
  operation-scoped approval; a grant for one operation class must not authorize
  another. v0.12 conversation history is SQLite local workspace context, not
  markdown memory and not hosted authentication; preserve `user_id`,
  `operator_id`, `thread_id`, and optional `session_id` across runtime-facing
  metadata, and do not auto-promote conversation turns into markdown memory.
  v0.15 app registration is local contract metadata only; app ids, app skill
  paths, surfaces, and action capability tags must not grant permissions,
  create dynamic routes, load code from arbitrary folders, or bypass Security
  Central.
- Do not auto-generate, compile, or load Elixir modules from arbitrary skill
  folders.
- Do not execute skill scripts, shell commands, external installs, or network
  adapters unless a plan explicitly adds the permission, confirmation, sandbox,
  and trace story.
- Do not call `npx skills add`, `git clone`, package managers, or external
  installer CLIs from skill activation, online skill search, imported skill
  metadata, or model output. v0.10 online import must leave imported skills
  disabled and untrusted under `<ALLBERT_HOME>/cache/skills`.
- Do not treat OTP supervision, BEAM processes, or local child processes as an
  OS security boundary. v0.08 local execution must be policy-bounded host
  execution through registered actions; deeper container or remote isolation
  requires a later plan and ADR update.
- Use `Req` for HTTP. Do not add `:httpoison`, `:tesla`, or `:httpc`.

## Workflow

- For docs-only changes, run `git diff --check`.
- For code changes, run focused tests first, then finish with the milestone
  warning gate: `mix compile --warnings-as-errors`, `mix credo --strict`,
  `mix dialyzer`, and `mix precommit` unless the user explicitly scopes the
  work differently.
- Every implementation milestone must be warning-free before commit or handoff:
  no compiler warnings, no formatter drift, no Credo findings, no Dialyzer
  warnings, and no focused-test or precommit failures.
- Update request-flow docs as implementation changes.
- Add or update ADRs when an implementation decision constrains future design.
- Keep LiveViews thin: they call contexts/actions/runtime boundaries and do not
  own agent logic, settings semantics, or security policy.
