# Allbert Operator Onboarding

This guide is the operator-facing entry path for trying Allbert from a fresh
checkout. It is not a release test matrix. Release-specific smoke commands live
in the matching request-flow document.

## Orientation

Read these first:

- `README.md` for the project overview and current capability summary.
- `CHANGELOG.md` for release status, safety notes, verification summary, and
  expected tag.
- `docs/plans/roadmap.md` for version sequencing.
- `docs/plans/v0.37-plan.md` and `docs/plans/v0.37-request-flow.md` for the
  current dynamic capability integration implementation contract.
- `docs/plans/v0.36-plan.md` and `docs/plans/v0.36-request-flow.md` for the
  sandbox and gate-runner prerequisite.
- `docs/operator/sandbox-gate-runner.md` when testing risky generated
  Elixir/OTP draft execution.
- `docs/operator/dynamic-capability-integration.md` when reviewing generated
  draft evidence, live integration, rollback, or emergency disablement.

## First Local Run

Use a disposable Allbert Home when exploring:

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-operator.XXXXXX)"
export ALLBERT_TRACE_ENABLED=true
```

Set up and run the app:

```sh
mix setup
mix phx.server
```

Open the local operator surfaces:

```text
http://localhost:4000/workspace
```

Try the CLI surface:

```sh
mix allbert.ask "hello"
mix allbert.security status
mix allbert.confirmations list
```

## Planned v0.39 First-Run Onboarding

`docs/plans/v0.39-plan.md` promotes first-run onboarding, provider/model
control, an optional identity memory slot, and deterministic Active Memory into
the planned 1.0 arc. That flow is not implemented yet. Until v0.39 ships, use
the manual setup commands in this guide and the release-specific request-flow
documents.

## v0.38 Templated Creation

`docs/plans/v0.38-plan.md` promotes deterministic creation patterns: developers
scaffold reviewed plugin/app/LLM-tool/scheduled-flow/objective patterns through
`mix allbert.gen.{plugin,app,tool,flow}` (`--target` defaults to
`./plugins/<name>`; `--force` plus preview/diff is required to overwrite an
existing root), and operators open a separate `workspace:create` Canvas
destination to render a vetted template, preview, validate, and choose
developer-scaffold or supported live-integration intent. The Create surface
routes effectful work through registered template actions: developer-scaffold
mode writes inert reviewed source, while supported live-integration mode writes
only a v0.37 draft and returns the explicit trial/gate/integration next steps.
In v0.38, only the LLM-tool (action)
template can live-integrate; the other patterns are developer-scaffold-only
because the v0.37.5 loader does not accept generated apps, panels, settings
fragments, memory namespaces, or objective wiring as live targets. Templated
drafts share
`<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/` with v0.37 codegen drafts and
are inspectable through `mix allbert.dynamic drafts list/show/discard`. See
`docs/operator/templated-creation.md` for the operator flow. The v0.39
onboarding destination is a separate planned Canvas destination, not the same
as `workspace:create`.

## What To Notice

- User input enters the runtime, not the UI layer.
- Runtime-facing work goes through registered Jido actions and the shared
  action runner.
- Risky work pauses as durable confirmation records before execution.
- CLI and `/workspace` render runtime state through the same action/context
  boundaries.
- Allbert Home contains the local runtime data for settings, confirmations,
  memory, traces, caches, and audits.

## Trying Risky Capabilities

Do not use a real `~/.allbert` while testing risky capabilities. Use the
release request-flow smoke matrix with a disposable home and workspace:

- v0.08 local shell execution: `docs/plans/v0.08-request-flow.md`
- v0.09 trusted skill script execution: `docs/plans/v0.09-request-flow.md`
- v0.10 external service, package install, and online skill import:
  `docs/plans/v0.10-request-flow.md`
- v0.36 generated Elixir/OTP sandbox gate runner:
  `docs/plans/v0.36-request-flow.md`
- v0.37 generated capability integration:
  `docs/plans/v0.37-request-flow.md`

v0.10 external-network testing should confirm that approval and target
execution are distinct. If a source HTTP/transport failure happens after
approval, the operator decision remains `approved` and the target result should
show `target_status=failed` with a visible failure reason.

v0.10 is implemented through M14 after the reopened M6-M9 sequence and was
released and tagged as `v0.10` on 2026-05-04. M12 landed the URI-first
`resource_uri` resource/grant authority. M13 added
`mix allbert.skills import-url` for direct HTTPS skill URLs and
`mix allbert.skills import-local` for local skill directories. Both import
disabled, untrusted, inactive, non-executable candidates under Allbert cache.
M14 added explicit unsupported/deferred UX for URL/document summarization,
document extraction, MCP/agent resource calls, broad web browsing/crawling,
and future channel-native approval handoff.

Remembered grant testing should use disposable confirmations and resources:

```sh
mix allbert.confirmations approve <confirmation-id> --reason "remember exact" --remember exact
mix allbert.resources grants list
mix allbert.resources grants show <grant-id>
mix allbert.resources grants revoke <grant-id> --reason "done testing"
```

For package installs or other multi-resource actions, approve with
`--remember exact --remember-all` only when every exact resource in the
request should be remembered for that operation. A target directory grant
alone does not authorize package registry/package-spec access.

## Safety Defaults

- Keep secrets in Settings Central secrets, not shell history or docs.
- Keep imported skills disabled and untrusted until reviewed separately.
- Treat Level 1 shell/script execution as host execution with policy controls,
  not OS isolation.
- Treat the v0.36 Elixir/OTP sandbox as default-off, report-only OS isolation
  for generated draft trials. Use approved local images only, prepare them
  through `mix allbert.sandbox image build` / `image verify`, and keep network
  disabled for sandbox gate runs.
- Treat v0.37 dynamic generation and live loading as separate default-off
  switches. `dynamic_codegen.enabled=true` may create source-bearing read-only
  action drafts, but those drafts remain untrusted evidence;
  `dynamic_codegen.live_loader_enabled=true` still cannot register authority
  without a v0.36 gate pass, trusted validation, and Security Central
  confirmation from a high-trust operator surface.
- Treat v0.10 network access as approved resource acquisition, not a browser,
  crawler, or arbitrary document summarizer.
- Treat remembered resource grants as Settings Central approval memory, not
  trust or execution authority. Grants are scoped by resource, operation,
  access mode, and downstream consumer, and still require Security Central
  policy re-check with the current action permission.
- Treat canonical `resource_uri` fields as the authority for matching. Redacted
  display URLs and rendered resource lines help operators inspect requests,
  but they are not remembered grant scopes.
- Pre-M12 remembered grants without `resource_uri` are not matched by the
  current pre-1.0 schema; re-create any still-needed grants through approval or
  `mix allbert.resources` flows.
- Use operation-scoped approvals for local path access, URL summaries,
  document inspection, local skill directory import, and direct skill URL
  import work.
- Treat `mcp://`, `agent://`, and `agent+https://` as unsupported future URI
  identities until a later release adds explicit actions, security policy,
  approval UX, adapters, traces, audits, and tests.

## Release Acceptance

Before accepting a release:

- Read `CHANGELOG.md`.
- Read the version plan and request-flow documents.
- Run the documented smoke matrix against a disposable Allbert Home.
- Confirm `git diff --check` and the release gates listed in the version plan
  passed.
- Confirm the expected tag name and whether the tag has already been created.
