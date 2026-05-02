# ADR 0008: Durable Confirmation Requests As Action State

## Status

Accepted.

## Context

Allbert now has Security Central, Settings Central, a Jido action runner, and
action-backed skills. The next roadmap step is confirmation workflow for
sensitive capabilities.

A confirmation prompt could be implemented as transient CLI or LiveView state,
but that would split policy and behavior by channel. It would also make future
jobs, channels, execution adapters, and traces difficult to reason about. The
same pending action should be visible from CLI and LiveView, survive process
restarts, carry the original Security Central decision, remember which channel
originated the request, remember which channel resolved it, and be auditable
after approval or denial.

At the same time, approval is dangerous if it becomes a generic bypass. Skill
metadata, model output, and UI clients must not be able to turn a denied or
unimplemented capability into executable authority by manufacturing an
"approved" flag.

## Decision

Allbert confirmation requests are durable action state stored under Allbert
Home. They are created only by registered actions that have reached a
Security Central `:needs_confirmation` decision and have avoided the target
side effect.

Approval, denial, expiration, listing, and inspection are themselves
registered Jido actions invoked through `AllbertAssist.Actions.Runner.run/3`.
CLI, LiveView, future jobs, and future channels must use those actions instead
of directly owning queue semantics or mutating confirmation files.

Approval re-reads the stored pending request, re-checks Security Central with
confirmation context, and may resume only the registered target action named in
the record. The target action still owns schema validation, permission checks,
redaction, and side effects. Approval does not bypass safety floors and does
not grant capabilities that are denied or unimplemented in the current release.

Confirmation records distinguish origin channel metadata from resolver channel
metadata. The origin channel is where the request was created; the resolver
channel is where approval, denial, expiration, or cancellation happened. In the
current local single-operator runtime, cross-channel approval may be allowed by
default, but the handoff must be visible in the record, trace, and audit. A
future multi-user or hosted authorization model may require same actor, same
channel, explicit role, or channel-specific policy.

v0.07 approval of a request whose adapter is intentionally unavailable, such as
external network access before v0.10, records an `adapter_unavailable` outcome
and performs no target side effect.

## Consequences

- v0.07 has one confirmation queue shared by CLI and LiveView.
- Pending, approved, denied, expired, cancelled, and adapter-unavailable
  outcomes are inspectable and auditable.
- Confirmation state can include selected skill, capability contract, action,
  permission, risk, redaction, origin actor/channel/session, resolver
  actor/channel/session, signal, runner, and trace metadata without trusting
  client-supplied params.
- Future execution adapters can consume confirmation context without inventing
  a separate approval mechanism.
- Safety floors remain authoritative: shell execution, skill scripts, package
  installs, online imports, real external network calls, and module loading
  still require their own later adapter, sandbox, and trace stories.
- The confirmation store is an implementation detail behind registered actions;
  pure storage helpers are acceptable there, but runtime-facing behavior must
  remain action-backed.
