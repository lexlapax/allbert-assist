# ADR 0038: MCP Client Trust Tier

## Status

Accepted for v0.40 MCP Client Integration (`docs/plans/archives/v0.40-plan.md`).
Accepted at v0.40 M1 closeout. Becomes a Tier-1 freeze candidate at v1.0 for
the permission classes, the `mcp://` resource identity, and the operation-class
vocabulary it introduces.

## Context

ADR 0013 reserves `mcp://` as an inert resource identity and `resource_uri.ex`
parks it in `@unsupported_schemes`. v0.40 promotes MCP client calls from parked
metadata to executable capability. MCP servers expose tools, schemas, and
resources, but those declarations cannot become authority inside Allbert.

The trust problem is specific. An MCP server is a remote (or locally spawned)
participant that Allbert did not write and does not sandbox. Its tool schemas,
resource lists, and tool/resource results are attacker-influenceable inputs:

- a server can advertise a tool whose schema or description tells the model to
  run a shell command, read a secret, or call another tool;
- a server can return resource content laced with prompt-injection text;
- a server can impersonate another server's identity or resource URIs;
- a stdio server is a local OS process whose argv and environment are a startup
  and secret-exposure surface (ADR 0009 local execution sandbox levels apply);
- an HTTP/SSE server is an external network egress target subject to the same
  SSRF, redirect, timeout, redaction, and audit posture as every other Allbert
  network call (ADR 0011, ADR 0012, ADR 0047).

ADR 0011 already anticipated this: it names "future MCP resources" as one more
consumer of the Resource Access Security Posture, and v0.10 M14 routed MCP/agent
calls to an explicit unsupported workflow rather than partial confirmations.
v0.40 is the milestone that turns that parked posture into a real, bounded
adapter.

The vision is binding here: no artifact above `Actions.Runner.run/3` grants
permission. MCP server presence, tool availability, and resource URIs are
descriptive metadata, never authorization (`docs/plans/allbert-jido-vision.md`;
ADR 0021).

## Decision

MCP client integration adds an explicit Allbert trust tier. MCP is one more
Resource Access consumer and one more registered-action family, not a second
runtime and not a trust root.

### 1. Configuration and secrets

- MCP server configuration lives in Settings Central under `mcp.servers.*`.
- Server transport, command/argv (stdio), base URL (HTTP/SSE), headers, and
  environment are configured through safe-write keys.
- All MCP secrets (API keys, bearer tokens, stdio env secrets) use Settings
  Central secret refs shaped as `secret://mcp/<server-id>/<name>`. Raw secret
  values never live in `settings.yml`, traces, or audits.

### 2. Metadata is never authority

MCP tools and resources are descriptive metadata until consumed by registered
Allbert actions. Tool schemas, tool descriptions, resource lists, and
tool/resource result bodies never:

- grant a permission,
- select or authorize another action,
- create or widen a Resource Access grant, or
- loosen a confirmation floor.

Every MCP effect passes through `Actions.Runner.run/3`, Security Central,
confirmations, Resource Access, traces, and audits, exactly like every other
effectful capability.

### 3. Permission classes

v0.40 adds two permission classes to `AllbertAssist.Security.Policy`, following
the `:package_install` / `:online_skill_import` precedent (ADR 0011):

- `:mcp_tool_call` — safety floor `:needs_confirmation`. MCP tool calls are
  effectful and are confirmed per call. Per-server/per-tool policy may tighten
  to `:denied` but may never drop below confirmation. There is no silent or
  remembered tool-call approval in v0.40 (remembered per-tool approval is
  explicitly parked in `future-features.md`).
- `:mcp_resource_read` — safety floor `:allowed`. The permission class does not
  itself force confirmation; authority comes from a remembered Resource Access
  grant scoped to the `mcp://` server/URI (see §4). The first read of a new
  server or resource scope requires operator approval that creates the grant;
  subsequent in-scope reads need no new confirmation. This supports v0.42's
  read-heavy workspace summary panels without per-read prompts.

Settings can tighten either class but cannot loosen `:mcp_tool_call` below the
`:needs_confirmation` floor. `:mcp_resource_read` cannot be configured to bypass
the Resource Access grant requirement.

Read-like MCP tools are still MCP tool calls in v0.40. A server may expose data
fetches as tools rather than resources, but that does not let Allbert apply an
`:mcp_resource_read` grant to `mcp_call_tool`. Such calls remain confirmed per
call unless a later ADR amendment introduces a narrower trust tier.

### 4. Resource identity and operation-class scoping

- MCP resources use `mcp://<server-id>/<encoded-uri>`, where `<server-id>`
  matches `[a-zA-Z0-9_-]+` and `<encoded-uri>` is the percent-encoded server
  resource URI.
- v0.40 removes `mcp` from `@unsupported_schemes` in
  `AllbertAssist.Resources.ResourceURI` and adds real `normalize`, `derive`, and
  encode support. `agent://` and `agent+https://` remain reserved/unsupported.
- v0.40 adds MCP operation classes to
  `AllbertAssist.Resources.OperationClass` (`:mcp_tool_call`,
  `:mcp_resource_read`), a `:call` access mode, and `mcp_server` / `mcp_tool`
  scope kinds. `:mcp_resource` already exists as an origin kind.

Operation class is part of the security boundary (ADR 0011). A remembered
`mcp_resource_read` grant must not authorize an `mcp_tool_call`; a tool-call
approval for tool A must not authorize tool B; and a grant for server A must not
authorize server B. Grants are matched on the canonical `mcp://` resource URI,
operation class, and downstream consumer.

### 5. Transports are adapters, not authority

v0.40 ships both transport families. Neither carries execution authority; both
are bounded adapters under existing Allbert posture.

- **HTTP / SSE (streamable HTTP, server-sent events)**: all egress routes
  through Allbert's `External.HttpClient` / `External.HttpPolicy` posture —
  SSRF blocking, host allowlist, bounded timeouts, bounded response bodies, no
  credential-bearing redirect following, and header/body redaction. MCP HTTP
  transports do not open a second, unconstrained network path.
- **stdio (local subprocess)**: the server process is started with explicit
  argv and an environment populated only from configured `secret://mcp/...`
  refs, never a shell string. Startup is bounded under ADR 0009 local execution
  sandbox levels: no arbitrary shell, bounded process lifecycle, and audited
  startup. WebSocket transport is deferred (see Non-Goals).

### 6. Protocol codec and dependency boundary

v0.40 uses the `hermes_mcp` library for MCP protocol framing/codec only. All
network and process egress is routed through an Allbert-owned transport so MCP
traffic stays inside the §5 posture. If `hermes_mcp` cannot cleanly route
through Allbert's transport posture, v0.40 falls back to a minimal native
JSON-RPC MCP client over `Req`; the fallback is decided and recorded at v0.40
M1. The MCP client is protocol-generic; it is not a provider-specific
dependency and does not violate ADR 0039's "no provider SDKs in core" rule.

### 7. Doctor reuse

`mcp_doctor_server` reuses the ADR 0047 doctor return shape and redaction
policy (`:read_only`, confirmation `:not_required`). It probes only a configured
server entry for transport reachability and tool/resource discovery and returns
a redacted, fixed-catalog diagnostic envelope plus MCP-specific additive fields.
It grants no tool or resource authority and creates no remembered grants.

## Consequences

- MCP unlocks ecosystem integrations without importing MCP's trust model. Every
  MCP effect still passes through `Actions.Runner.run/3`, Security Central,
  confirmations, Resource Access, traces, and audits.
- v0.40 must flip existing behavior, not only add new behavior: the intent
  agent currently routes `mcp://` and "mcp tool/resource/call" requests to the
  unsupported-resource workflow, and tests assert `status == :unsupported`.
  v0.40 rewrites that routing and those tests.
- Security Central gains `:mcp_tool_call` and `:mcp_resource_read`; Settings
  Central gains the `mcp.servers.*` namespace and `secret://mcp/...` refs;
  Resource Access gains MCP operation classes, access mode, and scope kinds.
- v0.42 consumes the v0.40 actions (`mcp_list_tools`, `mcp_list_resources`,
  `mcp_read_resource`, `mcp_call_tool`) and the grant-gated read model to render
  calendar/mail/GitHub workspace summary panels. v0.40's first-server validation
  set is aligned to those consumers plus deterministic mock servers and records
  whether required panel data is exposed as resources or only as tools. Tool-only
  panel reads must remain operator-triggered/per-call-confirmed, be parked, or
  receive an explicit ADR amendment before v0.42 implementation.
- The `:mcp_tool_call` / `:mcp_resource_read` permission classes, the `mcp://`
  identity, and the MCP operation-class vocabulary become Tier-1 freeze
  candidates at v1.0; changing them requires an ADR amendment and, for settings
  shape, an ADR 0046 migration.

## Non-Goals

- No MCP Apps iframe or third-party remote UI model (parked,
  `future-features.md`; MCP server mode is v0.51 and other public protocol
  surfaces are post-1.0).
- No `agent://` or `agent+https://` endpoint execution (parked).
- No automatic trust from tool schemas, descriptions, or results.
- No code-bearing plugin install through MCP.
- No silent or remembered MCP tool-call approval in v0.40.
- No WebSocket transport in v0.40 (HTTP/SSE and stdio only).
- No MCP server authority over Allbert permissions, grants, or confirmations.

## Amendments

### v0.42 (ADR 0048): discovered servers are inert until the connect gate

v0.42 adds internet tool discovery (ADR 0048). A server returned by discovery is
not configured and carries no authority: its `server.json` metadata and
advertised tool definitions are descriptive only, exactly like §2. A discovered
server enters this trust tier only after the confirmation-gated
`mcp_server_connect` action writes its `mcp.servers.<id>` entry behind a
pre-configuration consent that shows the exact untruncated run command / remote
URL. At connect time Allbert records a tool-definition baseline hash; on reconnect
(and on `mcp_doctor_server`) a changed hash — a rug-pull — forces re-review and
re-consent rather than silent trust continuation. Nothing in discovery loosens
the `:mcp_tool_call` or `:mcp_resource_read` floors defined above.

## Alternatives Considered

- **Native MCP client only (no library)**: rejected as the default but kept as
  the documented fallback. A native JSON-RPC client maximizes control but
  duplicates protocol/version handling that `hermes_mcp` already maintains.
- **Adopt `hermes_mcp` transports wholesale**: rejected. Its transports would
  open network/process egress outside Allbert's `External.HttpPolicy` and ADR
  0009 startup posture, splitting the SSRF/redaction/audit boundary.
- **One MCP permission class for both tools and resources**: rejected. Tool
  calls are effectful and must confirm; resource reads are read-heavy and need a
  grant-gated path so v0.42 panels do not prompt on every read. Collapsing them
  would either over-prompt reads or under-confirm tool calls.
- **Defer stdio to a later milestone**: considered. stdio is the larger security
  surface, but many reference MCP servers ship as npx/uvx stdio processes, and
  v0.42 needs them; v0.40 includes stdio under ADR 0009 bounds rather than
  shipping an HTTP-only client that v0.42 would outgrow immediately.

## References

- `docs/plans/archives/v0.40-plan.md` — v0.40 MCP Client Integration.
- `docs/plans/archives/v0.40-request-flow.md` — v0.40 request flow and security evals.
- `docs/plans/archives/v0.42-plan.md` — v0.42 MCP-First Integration Pack 1 (downstream
  consumer of the v0.40 MCP actions and grant-gated read model).
- ADR 0009 — Local Execution Sandbox Levels (stdio process startup bounds).
- ADR 0011 — Confirmed External Capability Adapters (operation-class scoping,
  bounded HTTP adapter precedent, "future MCP resources").
- ADR 0012 — Resource Access Security Posture.
- ADR 0013 — URI-First Resource Identity (`mcp://` graduation).
- ADR 0021 — Intent, Objective, Capability, And Advisory Boundary (metadata is
  never authority).
- ADR 0039 — MCP-First, Native-Plugin-Second Integrations.
- ADR 0046 — Settings Schema Migration Policy (`mcp.servers.*` evolution).
- ADR 0047 — Provider Doctor Contract (`mcp_doctor_server` return shape).
- ADR 0048 — Tool Discovery, Source Port, And Discovered-Server Trust (the
  connect gate by which a discovered server enters this trust tier).
