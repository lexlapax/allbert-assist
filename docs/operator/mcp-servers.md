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

## Discover A Server (v0.42)

v0.42 adds tool discovery so you can find an MCP server instead of knowing its
config in advance. Discovery, connect consent, the passive suggestions surface,
and the first MCP-configured integration panels are implemented in `0.42.0` (see
`docs/plans/v0.42-plan.md`).

Discovery is off by default. Enable it, then search local tools and internet MCP
registries. The official MCP Registry is the default remote source; optional
keyed sources such as PulseMCP are skipped unless their Settings secret refs are
configured:

```sh
mix allbert.settings set mcp.discovery.enabled true
mix allbert.mcp discover "calendar"          # internet MCP registries
mix allbert.tools find "calendar"            # local tools + internet, merged
```

`mix allbert.tools find` always searches local registered actions, skills, and
already-configured MCP servers under the read-only permission. Its internet
registry branch is conditional: `permissions.tool_discovery` must allow
`:tool_discovery`, otherwise the command returns local candidates only plus a
diagnostic that the MCP registry source was skipped.

Discovery is read-only and connects nothing: results are candidates, and internet
candidates are marked not-yet-usable. Connecting is a separate,
confirmation-gated step that shows you the exact run command or URL before it
writes any `mcp.servers.<id>` config:

```sh
mix allbert.mcp connect --candidate-id "remote_mcp:official:..."  # exact, unambiguous
mix allbert.mcp connect "io.example/calendar"                     # unique candidate name
```

Bare connect input resolves an exact candidate id first, then a unique candidate
name. If more than one candidate has the same name, the command prints a
disambiguation error and you should rerun it with `--candidate-id`.

An optional background scan (opt-in, paused by default) writes suggestions to a
passive Discovery Suggestions panel you review on your own time — Allbert never
messages you unprompted and never connects from a scan:

```sh
mix allbert.mcp scan enable        # then resume to schedule; or run once:
mix allbert.mcp scan run-once
```

Allbert records registry manifest metadata separately from the live trust
baseline. If you approve connect with `enable_on_connect=true`, Allbert attempts
one live `tools/list` capture after writing the server settings. Otherwise the
server stays in `pending_live_verification` until the first successful doctor
run captures the live baseline. Later doctor/reconnect checks compare only live
tool definitions to that live baseline; a change (a "rug-pull") is flagged for
review rather than silently trusted.

## v0.42 Integration Capability Inventory

v0.42's first integration pack is MCP-configured for calendar, mail, and GitHub,
plus a native notes/files reference path. The v0.40 MCP client matrix is the
authority boundary:

| Integration | Server id | Recommended server shape | v0.40 actions that drive the panel | Read exposure | Effectful exposure | Panel UX rule |
|---|---|---|---|---|---|---|
| Calendar | `calendar` | Resource-oriented calendar MCP server when available; tool-only servers remain supported but less automatic. | `mcp_list_tools`, `mcp_list_resources`, `mcp_read_resource`, `mcp_call_tool` | Agenda/event refresh uses `mcp_read_resource` only when the server exposes read-only resources such as event lists or calendar summaries. | Create/update/delete and availability tools are `mcp_call_tool` and remain per-call confirmed. | If no resource-backed read is exposed, the panel must show an operator-triggered confirmed-tool action or a clear empty/configure state. It must not promise prompt-free agenda refresh. |
| Mail | `mail` | Resource-oriented mail MCP server for mailbox/thread/message reads. | `mcp_list_tools`, `mcp_list_resources`, `mcp_read_resource`, `mcp_call_tool` | Header, thread, and message-body summaries should use `mcp_read_resource` with remembered Resource Access grants when resources exist. | Send/reply/label/archive/search tools are `mcp_call_tool`; write-like flows are confirmed every time. | The panel can refresh read resources under grants, but sends/modifications always route through Approval Handoff. |
| GitHub | `github` | Official GitHub MCP server or a compatible server exposing repository artifacts as resources where possible. | `mcp_list_tools`, `mcp_list_resources`, `mcp_read_resource`, `mcp_call_tool` | Repository files, issue/PR artifacts, and comments prefer resources when exposed. | Search, mutation, workflow, comment, and issue creation tools are confirmed `mcp_call_tool` calls. | Overview panels use resources for inspectable artifacts and keep tool-backed search/mutations operator-triggered. |
| Notes/files | `notes_files` | Native Allbert plugin/reference path, not an MCP server. | Plugin-owned `search_notes`, `read_note`, `write_note` actions and workspace panels. | File reads map to `file://` `read_local_path` Resource Access refs under the configured notes root. | `write_note` maps to `file://` `write_local_path` refs and the dedicated `:notes_file_write` confirmation floor. | No MCP grant is reused for local file IO; the `:notes_files` memory namespace is non-writable and never auto-promotes. |

v0.42 ships the Calendar, Mail, GitHub, and Notes/files workspace
destinations:
`/workspace?destination=workspace:calendar`,
`/workspace?destination=workspace:mail`,
`/workspace?destination=workspace:github`, and
`/workspace?destination=app:notes_files`. Calendar, Mail, and GitHub panels
inspect configured MCP servers through the registered MCP actions above. They
render resource previews only when an applicable remembered `mcp://` grant
exists; otherwise they show an
approval affordance or a per-call-confirmed tool summary. Create-event, reply,
and GitHub comment buttons route through Approval Handoff before any MCP
transport call.

### Calendar MCP Example

Prefer a resource-backed calendar server for the M7 agenda panel. Leave the
server disabled until credentials are configured and doctor/list checks pass.

<!-- v0.42-m6-config:calendar:start -->
```sh
mix allbert.settings set mcp.servers.calendar.enabled false
mix allbert.settings set mcp.servers.calendar.transport streamable_http
mix allbert.settings set mcp.servers.calendar.base_url https://calendar-mcp.example.invalid/mcp/
mix allbert.settings set mcp.servers.calendar.auth_ref secret://mcp/calendar/token
mix allbert.settings set mcp.servers.calendar.tool_allowlist '["list_calendars","list_events","get_event","find_availability","create_event","update_event"]'
mix allbert.settings set mcp.servers.calendar.confirmation required
```
<!-- v0.42-m6-config:calendar:end -->

### Mail MCP Example

Use resources for mailbox/thread/message reads when the server exposes them.
Send, reply, label, archive, and other modifying flows stay confirmed tool
calls.

<!-- v0.42-m6-config:mail:start -->
```sh
mix allbert.settings set mcp.servers.mail.enabled false
mix allbert.settings set mcp.servers.mail.transport streamable_http
mix allbert.settings set mcp.servers.mail.base_url https://mail-mcp.example.invalid/mcp/
mix allbert.settings set mcp.servers.mail.auth_ref secret://mcp/mail/token
mix allbert.settings set mcp.servers.mail.tool_allowlist '["list_threads","read_message","search_messages","send_message","modify_labels"]'
mix allbert.settings set mcp.servers.mail.confirmation required
```
<!-- v0.42-m6-config:mail:end -->

### GitHub MCP Example

The v0.40 real-server smoke used the official GitHub MCP Docker image over
stdio. The example below keeps it disabled until the token is stored as
`secret://mcp/github/pat` and the operator explicitly enables it.

<!-- v0.42-m6-config:github:start -->
```sh
mix allbert.settings set mcp.stdio.allowed_launchers '["docker","npx","uvx"]'
mix allbert.settings set mcp.servers.github.enabled false
mix allbert.settings set mcp.servers.github.transport stdio
mix allbert.settings set mcp.servers.github.command docker
mix allbert.settings set mcp.servers.github.args '["run","-i","--rm","-e","GITHUB_PERSONAL_ACCESS_TOKEN","ghcr.io/github/github-mcp-server"]'
mix allbert.settings set mcp.servers.github.env '{"GITHUB_PERSONAL_ACCESS_TOKEN":"secret://mcp/github/pat"}'
mix allbert.settings set mcp.servers.github.tool_allowlist '["get_issue","list_issues","get_pull_request","list_pull_requests","create_issue_comment","search_code"]'
mix allbert.settings set mcp.servers.github.confirmation required
```
<!-- v0.42-m6-config:github:end -->

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
