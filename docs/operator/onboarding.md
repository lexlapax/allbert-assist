# Allbert Operator Onboarding

This guide is the operator-facing entry path for trying Allbert from a fresh
checkout. It is not a release test matrix. Release-specific smoke commands live
in the matching request-flow document, especially
`docs/plans/v0.10-request-flow.md` for v0.10.

## Orientation

Read these first:

- `README.md` for the project overview and current capability summary.
- `CHANGELOG.md` for release status, safety notes, verification summary, and
  expected tag.
- `docs/plans/roadmap.md` for version sequencing.
- `docs/plans/v0.10-plan.md` and `docs/plans/v0.10-request-flow.md` for the
  current v0.10 release scope and smoke matrix.
- `docs/plans/v0.11-plan.md` for the next execution-aware Approval Handoff and
  Resource Access Security Posture work.

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
http://localhost:4000/agent
http://localhost:4000/settings
```

Try the CLI surface:

```sh
mix allbert.ask "hello"
mix allbert.security status
mix allbert.confirmations list
```

## What To Notice

- User input enters the runtime, not the UI layer.
- Runtime-facing work goes through registered Jido actions and the shared
  action runner.
- Risky work pauses as durable confirmation records before execution.
- CLI and `/settings` render the same confirmation records and call the same
  approval/denial actions.
- Allbert Home contains the local runtime data for settings, confirmations,
  memory, traces, caches, and audits.

## Trying Risky Capabilities

Do not use a real `~/.allbert` while testing risky capabilities. Use the
release request-flow smoke matrix with a disposable home and workspace:

- v0.08 local shell execution: `docs/plans/v0.08-request-flow.md`
- v0.09 trusted skill script execution: `docs/plans/v0.09-request-flow.md`
- v0.10 external service, package install, and online skill import:
  `docs/plans/v0.10-request-flow.md`

v0.10 external-network testing should confirm that approval and target
execution are distinct. If a source HTTP/transport failure happens after
approval, the operator decision remains `approved` and the target result should
show `target_status=failed` with a visible failure reason.

v0.10 is implemented through M9 after the reopened M6-M9 sequence, but the
release remains open for M10-M13 closeout before operator acceptance. Expected
tag after acceptance is `v0.10`; no v0.10 tag has been created or pushed yet.

## Safety Defaults

- Keep secrets in Settings Central secrets, not shell history or docs.
- Keep imported skills disabled and untrusted until reviewed separately.
- Treat Level 1 shell/script execution as host execution with policy controls,
  not OS isolation.
- Treat v0.10 network access as approved resource acquisition, not a browser,
  crawler, or arbitrary document summarizer.
- Treat remembered resource grants as Settings Central approval memory, not
  trust or execution authority. Grants are scoped by resource, operation,
  access mode, and downstream consumer, and still require Security Central
  policy re-check with the current action permission.
- Use operation-scoped approvals for local path access, URL summaries,
  document inspection, local skill directory import, and direct skill URL
  import work.

## Release Acceptance

Before accepting a release:

- Read `CHANGELOG.md`.
- Read the version plan and request-flow documents.
- Run the documented smoke matrix against a disposable Allbert Home.
- Confirm `git diff --check` and the release gates listed in the version plan
  passed.
- Confirm the expected tag name and whether the tag has already been created.
