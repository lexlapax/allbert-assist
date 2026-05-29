# ADR 0048: Tool Discovery, Source Port, And Discovered-Server Trust

## Status

Proposed for v0.41 Tool Discovery + MCP-First Integration Pack 1
(`docs/plans/v0.41-plan.md`). Accepted at v0.41 M1 before any discovery action
lands.

## Context

Allbert can call tools it already has (registered actions, skills, and the
tools of MCP servers an operator already configured per v0.40 / ADR 0038), but
it has no way to answer "is there a tool for this, and if not, can I get one?"
without the operator manually knowing a server exists and hand-writing
`mcp.servers.*`.

The Model Context Protocol now has a discovery substrate. The official MCP
Registry (`registry.modelcontextprotocol.io`) froze its read API at v0.1, defines
a `server.json` schema, and invites third-party "subregistries/aggregators"
(PulseMCP, Glama, Smithery) to re-implement the same Generic Registry API. The
official registry remains preview with no durability guarantee, and its only
query is name-substring search; aggregators add semantic search, popularity, and
security signals.

Discovering and connecting to an internet MCP server is the riskiest operation
in this surface. The MCP security guidance treats local-server compromise
(malicious `npx`/`uvx` start commands), SSRF during discovery (the client fetches
server-controlled URLs), tool-poisoning / prompt-injection via tool descriptions,
and "rug-pull" (a server changing its tool definitions after approval) as
first-class threats, and it mandates a pre-configuration consent that shows the
exact command before a client runs anything.

Allbert's invariants already cover most of this if discovery is modeled
correctly: side effects go through named validated actions; advisory output may
propose but never authorize (ADR 0021); MCP schemas are descriptive, never
authority (ADR 0038); external egress goes through `External.HttpPolicy`
SSRF/timeout/redirect/redaction (ADR 0011/0047); and Allbert is reactive, not
proactively pushy.

## Decision

### 1. `find_tools` is a unified capability-discovery primitive over a source port

Discovery is exposed as `find_tools`, an orchestrator action that fans out, in
parallel, to adapters behind a tool-source port and returns a single ranked,
deduplicated list of normalized candidates. The first two adapters are:

- `find_local_tools` — read-only, no network, no confirmation. Inventories
  Allbert's existing capability surface: registered actions
  (`AllbertAssist.Actions.Registry.capabilities/0`), skills
  (`AllbertAssist.Skills.Registry.list/1`), and the `tools/list` of MCP servers
  the operator has already connected.
- `find_mcp_tools` — the internet cascade (search → fetch manifest → evaluate)
  across the official MCP Registry plus one no-auth aggregator, behind a registry
  provider port so a backend can be swapped or added without touching callers.

The port is the extension seam: a future `find_marketplace_tools` (v0.45) or
`find_skill_registry_tools` adapter slots in behind `find_tools` with no caller
change. Capability-source heterogeneity (the official registry's name-only
search, an aggregator's richer search) is hidden behind one normalized result.

### 2. Discovered ≠ usable: the `ToolCandidate` carries that distinction

Every adapter normalizes to a `ToolCandidate`:

```elixir
%{
  name: String.t(),
  description: String.t(),
  source: :local_action | :local_skill | :configured_mcp | :remote_mcp,
  usable_now?: boolean(),
  requires: :none | :connect_confirmation,
  provenance: map(),      # namespace match, verified/official flags, signing
  signals: map()          # popularity, recency, security-scan, source registry
}
```

Local candidates are `usable_now?: true, requires: :none`. A `:remote_mcp`
candidate is `usable_now?: false, requires: :connect_confirmation` — it is inert
descriptive metadata until it passes the connect gate. Tool descriptions from
discovered servers are untrusted content: they are surfaced verbatim as
metadata and never allowed to alter agent behavior, consistent with the
"schema is never authority" posture of ADR 0038.

### 3. Discovery actions are read-only and authorize nothing

`find_tools`, `find_local_tools`, and `find_mcp_tools` are registered actions
with execution mode `:read_only` and exposure `:internal`, run through
`Actions.Runner.run/3`. They create no grants and connect to nothing. A new
read-only permission class `:tool_discovery` (safety floor `:allowed`) gates the
remote search; the local fan-out needs no new authority. All remote registry
egress routes through `External.HttpPolicy` (HTTPS-only, private/link-local IP
block, redirect denial, bounded bodies, redaction). The registry is treated as a
non-durable cache: a snapshot is used when the registry is unreachable, and
discovery degrades to local-only rather than failing the turn.

### 4. The connect gate is the single dangerous transition

A discovered server becomes real only through `mcp_server_connect`
(`AllbertAssist.Actions.Mcp.ConnectServer`), a confirmation-gated action with a
new permission class `:mcp_server_connect` (safety floor `:needs_confirmation`,
which settings cannot loosen). On invocation it:

1. presents a pre-configuration consent confirmation
   (`Confirmations.create/2`) whose `params_summary` shows the **exact,
   untruncated** resolved run command + argv (stdio) or remote URL (HTTP/SSE),
   the required env/header secret refs by name, the requested transport, and the
   `EvaluationReport` (provenance level, dangerous-command flags);
2. on operator approval (`Confirmations.resolve/4`), writes the
   `mcp.servers.<id>` entry through the existing v0.40 Settings path (server is
   written `enabled: false` unless the operator opts to enable on connect);
3. records a tool-definition baseline hash for the connected server.

There is no auto-connect. Reconnecting (or the next doctor run) re-verifies the
baseline hash; a change — a rug-pull — forces re-review and re-consent rather
than silent trust continuation. A connected server then lives entirely under the
ADR 0038 MCP client trust tier; discovery grants it nothing beyond having been
written.

### 5. Background discovery is opt-in, paused-by-default, and writes to a passive surface

Background scanning is an `AllbertAssist.Jobs` job (`target_type:
"registered_action"` running the discovery action) created `status: "paused"`,
behind `mcp.discovery.enabled: false` by default. When an operator enables and
resumes it, scans write `ToolCandidate`s to a passive "Discovery Suggestions"
workspace surface (an `AllbertAssist.Surface` panel, `visible_when:
:operator_opened`). Allbert never messages the operator unprompted about
discovery results and never connects from a scan; the operator reviews
suggestions on their own time and triggers `mcp_server_connect` explicitly. This
keeps the "reactive through v1.0" posture intact: the only autonomous behavior is
unattended read-only scanning into a queue the operator pulls from.

### 6. Provenance and danger signals are advisory inputs to consent, not authority

Evaluation scores provenance (official-namespace ownership match, verified /
isOfficial flags, signed Docker image / SBOM where available, version+hash
pinning) and flags dangerous run-command patterns (`sudo`, `rm -rf`, network
egress baked into argv, paths outside expected dirs). These rank candidates and
populate the consent surface. They never auto-approve or auto-reject; the
operator confirmation remains the authority, per ADR 0021.

## Consequences

- Allbert gains a general "what tool can satisfy this need?" primitive that the
  intent engine, the objective runtime, and operator queries can all reuse, with
  one normalized result and one extension seam.
- The integration pack (v0.41 panels) becomes a clean consumer: a panel can
  `find_tools "calendar"` and route an unconfigured operator into the connect
  gate, instead of assuming a hand-configured server.
- The dangerous surface is narrowed to one confirmation-gated action with a
  mandated, untruncated consent view and rug-pull re-verification; read-only
  discovery stays inside the existing HTTP policy and "schema is not authority"
  boundaries.
- Allbert takes no new network primitive, no new secret store, and no new
  runtime: discovery reuses `External.HttpPolicy`, the connect gate reuses
  Settings + Confirmations, and background scanning reuses `AllbertAssist.Jobs`.

## Non-Goals

- No auto-connect, and no remembered/silent connect approval.
- No proactive push messaging about discovery results (passive surface only;
  push remains parked under the Proactive Notifications Policy).
- No capability-gap-triggered discovery in the first cut (ADR 0033 objectives
  may consult `find_local_tools`, but gap-triggered remote acquisition is parked).
- No semantic / API-keyed registry source in the first cut (PulseMCP/Glama
  no-auth only; Smithery semantic search parked).
- No installation of code-bearing plugins through discovery — MCP servers only,
  through the v0.40 client boundary.
- No community trust scoring or registry-moderation authority; registry
  `status: deleted` is a hint, not sufficient trust.

## Relates To

- Depends on: ADR 0038 (MCP client trust tier — connected servers live here),
  ADR 0011/0047 (external HTTP/SSRF posture and doctor envelope reused for
  evaluation), ADR 0013 (`mcp://` identity), ADR 0021 (advisory boundary).
- Reuses: `AllbertAssist.Jobs` (background scan), `AllbertAssist.Surface`
  (suggestions panel), `AllbertAssist.Confirmations` (connect consent),
  `AllbertAssist.Actions.Registry` / `Skills.Registry` (local inventory).
- Related to: ADR 0033 (capability-gap acquisition — `find_local_tools` is the
  gap-detection primitive; gap-triggered discovery is a documented follow-on).
- Amends: ADR 0038 (discovered servers are inert until this connect gate;
  reconnect re-verifies the baseline hash).
