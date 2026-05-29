# Allbert MCP Servers Operator Guide

Status: implemented in v0.40 (`0.40.0`) and ready for operator manual
validation before release tagging.

This guide explains how to connect an MCP (Model Context Protocol) server to
Allbert, inspect what it offers, and let Allbert use it under policy. It is not a
release test matrix; release smoke commands live in
`docs/plans/v0.40-request-flow.md`.

## Orientation

Read these first:

- `docs/plans/v0.40-plan.md` for the implementation contract.
- `docs/adr/0038-mcp-client-trust-tier.md` for the trust model.
- `docs/operator/security-hardening.md` for the MCP threat surfaces.

## What An MCP Server Is To Allbert

An MCP server is an external participant (remote over HTTP/SSE, or a local
process over stdio) that advertises tools and resources. Allbert treats those
advertisements as **descriptive metadata, never authority**:

- a server's tool schemas and descriptions cannot grant Allbert a permission;
- a resource list cannot create or widen a grant;
- tool or resource result text cannot instruct Allbert to bypass its rules.

Every MCP effect runs through the same action runner, Security Central,
confirmations, Resource Access, traces, and audits as every other capability.

## Configure A Server

MCP servers live in Settings Central under `mcp.servers.<server-id>`. Secrets
(API keys, tokens, stdio env secrets) are stored as encrypted secret refs shaped
`secret://mcp/<server-id>/<name>`, never as plain text in `settings.yml`.

Use a disposable Allbert Home while exploring:

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-mcp.XXXXXX)"
export ALLBERT_TRACE_ENABLED=true
```

### Remote server (HTTP/SSE)

```sh
mix allbert.settings set mcp.servers.github.transport streamable_http
mix allbert.settings set mcp.servers.github.base_url https://your-github-mcp.example/mcp/
# Enter the token as an encrypted secret through the Settings Central secret
# path (stdin or the LiveView secret form), never as a plain argument, then
# point auth_ref at the ref:
mix allbert.settings set mcp.servers.github.auth_ref secret://mcp/github/token
mix allbert.settings set mcp.servers.github.enabled true
```

HTTP/SSE egress is subject to Allbert's network posture: SSRF blocking, host
allowlist, bounded timeouts and response sizes, no credential-bearing redirects,
and header/body redaction.

### Local server (stdio)

```sh
mix allbert.settings set mcp.stdio.allowed_launchers '["npx"]'
mix allbert.settings set mcp.servers.calendar.transport stdio
mix allbert.settings set mcp.servers.calendar.command npx
mix allbert.settings set mcp.servers.calendar.args '["-y","@example/calendar-mcp"]'
# Enter any stdio env secret through the Settings Central secret path, then
# reference it from mcp.servers.calendar.env (value is a secret ref, not a
# literal):
mix allbert.settings set mcp.servers.calendar.enabled true
```

A stdio server is a local OS process. Allbert starts it with explicit argv and an
environment populated only from your configured secret refs — never a shell
string — and bounds its lifecycle under the local-execution sandbox policy. The
launcher command must appear in `mcp.stdio.allowed_launchers`; the default empty
list denies stdio startup. Server stderr logs are kept separate from the MCP
stdout JSON stream.

`mix allbert.settings set` parses JSON values for MCP list/map settings, so
`args`, `tool_allowlist`, `tool_denylist`, `env`, and `headers` can be supplied
as JSON objects or arrays when needed.

## Discover A Server (planned, v0.42)

v0.42 adds tool discovery so you can find an MCP server instead of knowing its
config in advance. The commands below land with v0.42 (see
`docs/plans/v0.42-plan.md`); v0.40 operators configure servers manually as above.

Discovery is off by default. Enable it, then search local tools and internet MCP
registries:

```sh
mix allbert.settings set mcp.discovery.enabled true
mix allbert.mcp discover "calendar"          # internet MCP registries
mix allbert.tools find "calendar"            # local tools + internet, merged
```

Discovery is read-only and connects nothing: results are candidates, and internet
candidates are marked not-yet-usable. Connecting is a separate,
confirmation-gated step that shows you the exact run command or URL before it
writes any `mcp.servers.<id>` config:

```sh
mix allbert.mcp connect "io.example/calendar"   # shows exact command/URL; approve
```

An optional background scan (opt-in, paused by default) writes suggestions to a
passive Discovery Suggestions panel you review on your own time — Allbert never
messages you unprompted and never connects from a scan:

```sh
mix allbert.mcp scan enable        # then resume to schedule; or run once:
mix allbert.mcp scan run-once
```

Allbert records a tool-definition baseline when you connect. If a server later
changes its tool definitions (a "rug-pull"), the next doctor/reconnect flags it
and asks you to review again rather than silently trusting the change.

## Doctor A Server

Before trusting a server, run the doctor. It is read-only, requires no
confirmation, and returns a redacted reachability/discovery summary. It does not
grant any tool or resource authority.

```sh
mix allbert.mcp doctor github
```

The output reports transport kind, endpoint reachability, whether tools and
resources are listable, counts, and protocol version. It never prints secrets,
full URLs, or raw error bodies.

## List Tools And Resources

```sh
mix allbert.mcp tools github
mix allbert.mcp resources github
```

These return descriptive metadata only. Listing authorizes nothing.

## Read A Resource

The first time Allbert reads from a server scope, it asks you to approve a
Resource Access grant for that `mcp://` scope. Once granted, in-scope reads
proceed without prompting you again.

```sh
mix allbert.mcp read github "repo://owner/name/README.md"   # approve grant
mix allbert.mcp read github "repo://owner/name/README.md"   # no re-prompt
```

A grant for one server does not authorize another, and a read grant never
authorizes a tool call.

## Call A Tool

Tool calls are effectful, so **every tool call is confirmed**. You approve each
call before it runs; there is no silent or remembered tool-call approval.

```sh
mix allbert.mcp call github create_issue '{"repo":"owner/name","title":"..."}'
```

You can tighten policy per server:

- `mcp.servers.<id>.tool_allowlist` — only these tools may be called.
- `mcp.servers.<id>.tool_denylist` — these tools are always denied.
- `mcp.servers.<id>.confirmation` — `required` (default) or `denied`. You can
  tighten to `denied`; you cannot loosen below confirmation.

Disabled servers, denied tools, and out-of-allowlist tools cannot run.
Read-like MCP tools are still tool calls in v0.40. Resource Access grants apply
only to `mcp_read_resource`, not to `mcp_call_tool`.

## Inspect Traces And Audits

With tracing enabled, MCP turns record the `mcp://` resource URI, operation
class, permission decision, confirmation/grant reference, and redacted
diagnostics. Audit records capture doctor, list, read, and call interactions.
Secrets, full URLs, and raw tool/resource bodies are redacted everywhere.

```sh
rg 'mcp://' "$ALLBERT_HOME/memory/traces"
ls "$ALLBERT_HOME/mcp/audit"
```

## What Allbert Never Does With MCP

- It never treats a server's schemas, descriptions, or results as authority.
- It never auto-enables tools or auto-promotes MCP output into memory.
- It never executes `agent://` endpoints or runs MCP Apps iframe UI (parked).
- It never lets settings loosen a tool call below confirmation, or a resource
  read below its grant requirement.

## Troubleshooting

- Doctor reports the endpoint unreachable: check `base_url`/`command`, the
  host allowlist, and that the server is running.
- A tool call is denied without prompting: check `tool_denylist`,
  `tool_allowlist`, and `mcp.servers.<id>.confirmation`.
- Resource read keeps prompting: confirm the grant was approved for the scope
  you are reading, not a narrower one.
