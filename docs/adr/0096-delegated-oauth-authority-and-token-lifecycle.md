# ADR 0096: Delegated OAuth Authority And Token Lifecycle

## Status

Proposed (v1.6, 2026-07-30). Binding on the v1.6 OAuth substrate and both its
consumers — email XOAUTH2 mailboxes and OAuth-authenticated hosted LLM
providers. Flips Accepted when the substrate, both consumers, the local callback
listener, and the named revocation and expiry rows are green.

## Context

Every credential Allbert holds today is a **static secret**: an API key, a bot
token, a password. The tier vault stores it, Security Central decides what may
use it, and it changes only when the operator changes it.

v1.6 introduces the first credentials that are none of those things. OAuth grants
are:

- **delegated** — issued by a third party on the operator's behalf, carrying
  scopes that third party chose;
- **self-renewing** — a refresh token is standing authority to mint new access
  tokens, indefinitely, without further operator action;
- **externally revocable** — the operator, or the provider, can revoke a grant
  outside Allbert, and Allbert learns only when a call fails.

Two consumer families need this in the same release and would otherwise build it
twice. Email XOAUTH2 covers Gmail and Microsoft OAuth-only mailboxes, which are
increasingly the only way to reach a real mailbox. OAuth-authenticated hosted LLM
providers cover Claude, OpenAI, and Gemini subscription plans rather than
metered API keys — which materially changes the cost posture of anything that
calls a model in a loop, including v1.7 Knowledge ingest.

There is no existing credential or vault ADR to extend. This is the first, and
the questions it settles are not plan-shaped.

A third interaction forces the timing: OAuth's authorization-code flow needs a
**redirect URI**, which means a local HTTP listener. v1.6 also carries non-local
bind hardening. A callback listener and "harden what we bind" are the same
question asked twice, and deciding them in separate milestones is how they end
up inconsistent.

## Decision

### 1. Provider scope is not Allbert permission

An OAuth grant arrives carrying scopes the provider chose. Those scopes are
**evidence of what the provider will allow**, never a source of Allbert
authority. A grant with broad scopes does not widen what Allbert may do; a grant
with narrow scopes does not substitute for a Security Central decision.

The schema joins the existing Security Central list: skills, model output, app
and plugin metadata, YAML, descriptors, generated files, modes, surface policy —
and now provider-supplied OAuth scopes — grant no permission by themselves.

Concretely: Allbert requests the minimum scopes each consumer needs, records what
was granted for diagnostics and doctor output, and gates every use through the
same permission class it would use for a static credential.

### 2. Refresh tokens are a distinct credential class

A refresh token is not "a password that lasts longer". It is standing authority
to mint access tokens. It is therefore:

- stored only in the tier vault, never in settings, traces, logs, or audit
  bodies;
- redacted in every surface, matching existing secret-ref handling;
- separately revocable by the operator without re-authorizing from scratch where
  the provider supports it;
- never emitted to a model, a channel, an export, or a backup in plaintext.

Access tokens are treated as short-lived derived material and are not persisted
beyond their cache lifetime.

### 3. One substrate, two consumers

A single OAuth component owns the authorization-code flow, PKCE where the
provider supports it, token exchange, refresh, expiry tracking, and revocation.
Email and LLM-provider consumers configure it; neither reimplements it.

Consumer-specific concerns — mailbox selection, provider model catalogs — stay in
their own subsystems. The substrate knows about grants, not about mailboxes or
models.

### 4. The callback listener is a bound network surface

The redirect URI listener:

- binds **loopback only**, on an ephemeral port, for the duration of one
  authorization exchange, and shuts down immediately after;
- accepts exactly one callback, matched by a cryptographically random `state`
  value bound to the initiating request;
- is governed by the same non-local bind rules landing in this release — there is
  one bind policy, not a general one and an OAuth exception;
- never runs as a persistent service and is never reachable from a non-loopback
  interface.

An authorization that does not complete within a bounded window fails closed and
tears the listener down.

### 5. Revocation and expiry fail closed and surface honestly

When a refresh fails because the grant was revoked or expired:

- the consumer operation fails with a typed, distinguishable reason — not a
  generic auth error;
- the grant is marked needing re-authorization rather than silently retried;
- the operator is told which provider and which consumer, through the normal
  doctor and settings surfaces;
- no automatic re-authorization is attempted, because re-authorization is an
  operator act.

Mid-operation revocation during a long-running batch (a fan-out, a Knowledge
ingest run) halts the batch at a resumable boundary rather than failing every
remaining item individually.

### 6. Authorization is always an explicit operator act

Starting an OAuth flow opens a browser and requires the operator to approve at
the provider. That flow is never initiated by model output, by a channel
message, by a schedule, or by any autonomous path. A registered action starts it,
the operator completes it, and the grant is recorded.

## Consequences

- Both consumers gain OAuth for the cost of one substrate, and later consumers
  are cheap.
- Subscription-plan authentication for hosted LLM providers changes the cost
  model for model-heavy features; v1.7 Knowledge ingest is the first beneficiary
  and its token-budget design remains correct either way.
- One more credential class exists, with genuinely different lifecycle rules, and
  the vault gains a second shape to handle.
- Grants can break without Allbert doing anything wrong, so "needs
  re-authorization" becomes a normal, surfaced state rather than an error.
- A short-lived loopback listener exists during authorization — a new, bounded
  network surface governed by the same bind policy as everything else.

## Non-goals and guardrails

- No device-code or client-credentials flow in this release; authorization-code
  with PKCE only.
- No storing provider scopes as an authority source, in any form.
- No automatic, unattended re-authorization.
- No persistent callback service, and no non-loopback bind for it.
- No refresh token in export, backup, trace, log, audit body, or model context.
- No OAuth-specific exception to the bind policy.
- Multi-tenant or shared grants are out of scope; grants are operator-scoped, and
  hosted multi-user authorization remains parked.

## Validation

- Provider scope cannot widen an Allbert permission decision — an adversarial row
  granting broad scopes proves the decision is unchanged.
- Refresh tokens never appear in export, backup, traces, logs, audit bodies, or
  model context.
- The callback listener binds loopback only, accepts one `state`-matched
  callback, and is torn down on completion, timeout, and failure.
- A revoked grant produces a typed needs-re-authorization state, not a retry
  loop, and names the provider and consumer.
- Mid-batch revocation halts at a resumable boundary.
- An OAuth flow cannot be initiated by model output, a channel message, or a
  schedule.
- Both consumers exercise the same substrate — proven by a shared contract test,
  not by two parallel implementations.
