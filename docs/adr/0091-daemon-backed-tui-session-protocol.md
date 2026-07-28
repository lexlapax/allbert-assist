# ADR 0091: Daemon-Backed TUI Session Protocol And Thin Terminal Client

## Status

Proposed (v1.2.1 point enabler, operator-signed readiness decision
2026-07-28). Binding on the daemon-backed-TUI milestones in the active
release-line plan; flips Accepted when the packaged macOS and Linux rows prove
one daemon per Home, Web/TUI continuity, failure restoration, and no embedded
TUI runtime.

This ADR is an additive successor to ADR 0076's attach-first process model and
ADR 0067's TUI channel. It supersedes only the standalone/embedded
`allbert tui` exception and attach-failure behavior identified below. It does
not change the frozen command taxonomy, TUI channel identity, split payload,
confirmation, or Security Central contracts.

Related: ADR 0058 (external daemon supervision is a different construct), ADR
0067 (terminal channel and rendering model), ADR 0068 (Pi-mode), ADR 0070
(operator reads), ADR 0073 (thin cross-surface contract), ADR 0076 (packaged
daemon and local attach), and ADR 0083–0085 (durable fan-out and cancellation).

## Context

The packaged product currently has two process models. Runtime-backed one-shot
CLI commands attach to `allbert serve` over the authenticated Home-local Unix
socket, but `allbert tui` bypasses that dispatcher and starts a second
application tree to own the terminal. Operators must stop the service before
opening the TUI against the same Home. This duplicates Repo/migration/runtime
ownership and prevents Web and TUI from being simultaneous views of one
runtime.

The existing attach-v1 request is a bounded one-shot argv packet with no
`kind` field and one terminal response. Reinterpreting it as a streaming
session would break a shipped protocol. A TUI session also carries more than
stdout: typed input, live render frames, confirmations, fan-out status/report
delivery, Pi-mode raw input and Escape cancellation, detach, backpressure, and
terminal cleanup.

## Decision

### 1. One daemon owns product state; the client owns only the terminal

For a selected Allbert Home, the daemon exclusively owns:

- the application supervision tree, Repo, migrations, and SQLite writer
  discipline;
- runtime turn admission, channel session/thread state, identity resolution,
  and inbound dedupe;
- confirmations and their same-channel callback proof;
- fan-out subscriptions, durable report/receipt handling, and slash-command
  action dispatch; and
- Pi/coding session state, effect supervision, and cooperative cancellation.

The `allbert tui` process owns only TTY/raw-mode setup, line/key input,
presentation rendering, local transport flow control, and terminal restoration.
It opens no Repo, runs no migration, starts no provider/runtime supervisor, and
does not resolve identity or execute actions locally. Except for transport-local
detach/help needed to recover the terminal, slash commands are sent to and
interpreted by the daemon. The TUI remains the ADR 0067 first-class channel; its
adapter moves daemon-side rather than being reimplemented in the client.

The profile supplied at session open is an untrusted selector. Settings Central
and the daemon-side identity map resolve the effective verified operator. The
client cannot assert a `user_id`, confirmation id, trust class, or permission.

### 2. Add a typed session family without changing attach-v1

A packet with no `kind` retains the exact attach-v1 one-shot argv semantics.
It is never guessed to be a session packet. Long-lived terminal traffic uses
only an additive `kind: :tui_session` family with its own session-protocol
version and a closed frame allowlist.

The open handshake carries the existing per-Home token plus canonical Home,
OS uid, application version, attach protocol version, requested TUI profile,
and client render/input capabilities. The daemon compares token material in
constant time and rejects every Home/uid/application/protocol mismatch before
creating channel state. The Unix-domain socket and token remain local-only with
the existing owner-only filesystem permissions; Erlang distribution and a
loopback listener remain out.

After open, typed frames cover input lines, Escape/cancel, confirmation
commands, detach, daemon render/status/confirmation frames, terminal errors,
and close. Every frame has a bounded encoded size, session id, monotonic
sequence/correlation value, and validation before dispatch. Per-session inbound,
outbound, and in-flight queues are bounded. When the peer cannot keep up, the
connection closes with a stable overflow reason rather than buffering without
limit or silently double-executing input. Durable results remain inspectable
after reconnect; transient progress need not be replayed.

### 3. One active TUI session per Home, with explicit reconnect

Exactly one TUI attachment may own the terminal-channel session for a Home at a
time. A second client receives a bounded busy response; Web, messaging, and
one-shot CLI surfaces remain usable through the same daemon. This is a
deliberate first implementation bound, not a claim that the protocol can never
support multiple terminal profiles.

There is no live-session resume in this milestone. Socket loss, client exit, or
daemon close ends the attachment and tears down its transient input/render
state. A later `allbert tui` invocation performs a fresh authenticated open
and may render durable conversation, objective, confirmation, and job state
through ordinary daemon reads; it does not claim to resume a partially rendered
frame stream or reuse sequence state.

### 4. Failure is fail-closed for attachment and safe for the terminal

- If no matching daemon is reachable, `allbert tui` prints exact
  service-start/doctor guidance and exits. It never boots an embedded fallback.
- If a daemon is running but token, identity, version, protocol, capacity, or
  session negotiation fails, the client prints the redacted reason and repair
  guidance. It never starts a second writer.
- If the daemon cannot bind its attach socket, the runtime and Web stay up in an
  explicit healthy-but-degraded state. TUI and other commands that require that
  daemon attachment fail closed; the daemon health/doctor report names attach
  unavailability.
- Socket loss closes the attachment. Work already durably admitted as
  background work may complete and remain deliverable through another surface
  or a later fresh TUI session. An active effectful Pi/coding turn is
  cooperatively cancelled because its attended terminal custody is gone; it is
  never left executing merely in hope of a reconnect.

The client restores canonical terminal mode and clears its transient live
region on normal detach, `/quit`, authentication/session error, overflow,
socket loss, daemon shutdown, and handled termination signals. Restoration is
client-owned and idempotent; the daemon never writes terminal control state
directly. SIGKILL, power loss, or terminal-emulator failure cannot run client
cleanup. Operator diagnostics document `stty sane` and `reset` recovery; this
milestone does not add a watchdog solely for uncatchable termination.

### 5. Presentation and authority remain on existing spines

The daemon emits bounded typed surface payload/render frames; only canonical
model payload enters conversation memory under ADR 0067. Confirmations,
operator reads, ordinary turns, Pi actions, and cancellations still route
through the registered action/runtime boundaries. Session frames carry input
and presentation; they do not constitute a new capability or permission path.

Trace/audit records contain session lifecycle and trace-safe metadata, not raw
attach tokens or terminal-frame payloads. Input execution remains protected by
the existing inbound idempotency/receipt contracts, including when a client
retries after an ambiguous transport close.

## Consequences

- Web and TUI can remain open against one durable daemon and one Repo without
  the current service stop/restart dance.
- The terminal executable becomes small and failure-oriented; Runtime, identity,
  confirmation, fan-out, and Pi behavior are not duplicated into an IPC client.
- The existing one-shot attach protocol remains compatible because kind-absent
  packets retain their old meaning.
- One-session and no-live-resume bounds remove multiplexer/replay complexity
  from the first implementation while preserving durable runtime work.
- Attach availability becomes observable service health rather than an
  optimization that may silently create a competing writer.

## Non-goals And Guardrails

- No remote/routable TUI, Erlang distribution, browser terminal, or native
  desktop client.
- No second Repo, migration runner, Runtime, TUI adapter, identity resolver, or
  confirmation store in the terminal client.
- No live stream replay/resume or simultaneous terminal multiplexer in v1.2.1.
- No authority inferred from socket possession, local uid alone, profile name,
  render capabilities, or frame content.
- No fallback to an embedded TUI after any no-daemon or attach failure.

## Validation

Acceptance requires focused protocol/security tests for kind-absent v1
compatibility, token/Home/uid/application/protocol mismatch, malformed and
oversized frames, sequence/idempotency, one-session capacity, backpressure,
detach/socket-loss cleanup, Pi cancellation, durable background completion,
confirmation handoff, and terminal restoration.

Packaged macOS and Linux validation starts the service first, keeps it running
before/during/after TUI use, proves the TUI process opens no Repo or migration,
uses Web and TUI concurrently against the same conversation/runtime, exercises
fan-out and Escape cancellation, kills each side of the socket, and verifies
the terminal and service health after every handled failure. A separate
uncatchable-client-termination row proves the documented `stty sane`/`reset`
recovery without claiming in-process cleanup.
