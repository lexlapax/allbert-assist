# ADR 0091: Daemon-Backed TUI Session Protocol And Thin Terminal Client

## Status

Accepted (v1.2.1 M0.b1, 2026-07-28; operator-signed final-readiness decision).
Binding on the daemon-backed-TUI milestones in the active release-line plan.
The daemon session, integrity, and durable-receipt portion landed at M0.b2 on
2026-07-28; the terminal client and attended validation remain M0.b3/M0.c3.
The packaged macOS and Linux rows at M0.c3 must still prove one daemon per Home,
Web/TUI continuity, failure restoration, and no embedded TUI runtime before the
point release may ship; those rows validate this decision rather than delaying
its acceptance.

The final readiness pass freezes the exact atom-tagged v1 packet schema,
bounds, sequencing, acknowledgements, queues, drop order, and close reasons.
It also adds a minimal durable admission receipt that can be queried from a
fresh session after ambiguous transport close. It does not claim exactly-once
execution: admission with no provable terminal result after daemon restart is
reported as `outcome_unknown` and requires deliberate retry under a new
receipt. It adds no stream replay or second terminal runtime.

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

A packet with no `kind` retains the exact attach-v1 one-shot argv semantics and
remains what existing clients emit. Additive `kind: :command` is an explicit
alias for that same validation, execution, and one-response behavior; it never
changes a kind-absent packet. Long-lived terminal traffic uses only
`kind: :tui_session` with its own session-protocol version and a closed frame
allowlist. Any other present kind is rejected and is never guessed to be a
session packet.

The session protocol constant is `1`. The legacy packet retains its existing
1 MiB body cap and decoding behavior. A session `:open` body is at most 16 KiB;
every later body is at most 64 KiB. These bounds exclude the fixed length
prefix. Session ETF may nest at most eight containers; any map has at most 32
keys and any list is proper with at most 256 elements. The session decoder
rejects the ETF `COMPRESSED` tag before session semantic decoding, then decodes
with `[:safe]`, validates the structural bounds, and exact-matches only
pre-existing allowlisted atoms. The first packet shares the legacy attach-v1
envelope, so the transport performs its existing safe-term decode once to
discover the in-term `kind`; when the raw packet carried `COMPRESSED` and the
decoded kind is `:tui_session`, it rejects that packet before session schema,
identity, or runtime dispatch. Rejecting every compressed first packet before
reading `kind` would change kind-absent attach-v1 behavior, while adding an
out-of-band discriminator would change its wire framing; v1 does neither.
It never creates an atom from peer input. Unknown keys, atoms, frames, or value
types are v1 protocol errors, rather than fields to ignore.

The exact open shape is:

```elixir
%{
  kind: :tui_session,
  frame: :open,
  session_protocol: 1,
  protocol: attach_protocol_integer,
  home: canonical_home,
  uid: os_uid,
  version: application_version,
  token: home_attach_token,
  profile: requested_profile,
  terminal: %{
    columns: columns,
    rows: rows,
    color: :none | :ansi16 | :ansi256 | :truecolor,
    unicode?: boolean
  }
}
```

`home` is valid UTF-8 and at most 4,096 bytes; `uid` preserves the existing
Attach identity's canonical UTF-8 string and is 1–32 bytes; `version` is valid
UTF-8 and at most 64 bytes; and `profile` is normalized valid UTF-8 from 1
through 128 bytes. The token is exactly 43 bytes: the existing unpadded
base64url encoding of 32 random attach-token bytes.
Columns are 1–500 and rows are 1–200. The daemon compares token
material in constant time and rejects every Home, uid, application, attach-
protocol, or session-protocol mismatch before creating channel state. The
Unix-domain socket and token remain local-only with existing owner-only
filesystem permissions; Erlang distribution and a loopback listener remain
out. The existing five-second open-read deadline applies until this handshake
succeeds. M0.b2 adds a 16-client pending-handshake cap distinct from the
existing 16-child unary-command task cap; the current serial accept loop is not
claimed as that bound. An accepted session is no longer subject to the unary
command-response deadline and has no application idle timeout; socket loss,
daemon shutdown, explicit detach, or bounded-pressure failure ends it.

An accepted open receives the first daemon `:snapshot` as server sequence 1,
acknowledgement 0, with a cryptographically random 32-byte binary `session_id`.
Before acceptance, failure has the one bounded shape
`%{kind: :tui_session, frame: :close, session_protocol: 1, code: code,
message: message}` and the daemon closes the socket. Open codes are exactly
`:invalid_open`, `:unsupported_kind`, `:token_mismatch`, `:home_mismatch`,
`:uid_mismatch`, `:version_mismatch`, `:protocol_mismatch`, `:identity_denied`,
`:already_attached`, `:capacity`, and `:runtime_unavailable`; `message` is
redacted valid UTF-8 of at most 1,024 bytes.

Every accepted post-open body has exactly these envelope keys:

```elixir
%{
  kind: :tui_session,
  session_protocol: 1,
  frame: allowed_frame_atom,
  session_id: session_id,
  seq: positive_integer,
  ack: non_negative_integer,
  payload: exact_frame_payload
}
```

Sequence numbers start at 1 independently in each direction, increase by one,
and may not exceed `9_223_372_036_854_775_807`. That maximum is reserved for a
daemon-to-client terminal `:close` with `:sequence_error`; the client closes its
transport before using the maximum, and no other frame is admitted at it. Each
endpoint puts the highest
contiguous peer sequence synchronously handled or accepted into its bounded
queue into outgoing `ack`, starting at 0. An incoming frame's `ack` acknowledges
this endpoint's outgoing stream and must satisfy
`last_peer_ack <= ack <= local_highest_sent`. It acknowledges frame custody,
not action completion. A sequence gap, duplicate/regression, or exhaustion
closes with `:sequence_error`; an acknowledgement regression or impossible
value closes with `:ack_error`; a wrong session id, unknown key/type/frame,
compressed/invalid ETF, or other schema failure closes with `:protocol_error`;
and a body over 64 KiB closes with `:frame_too_large`.
Frames are not retransmitted: sequence and acknowledgement release bounded
in-flight storage and detect loss/corruption. An `:ack` frame has `%{}` payload,
participates in sequence ordering, is not retained in the unacknowledged
window, and never by itself causes another ack-only frame; every other outgoing
frame piggybacks the current ack.

The v1 daemon-to-client schema deliberately has no standalone `:ack` frame. If
quiet client traffic advances daemon custody without a new semantic
presentation, the daemon mirrors its current bounded `:status` payload with the
same render revision, state, text, and receipt reference. That semantic no-op
carrier advances the cumulative acknowledgement without inventing a protocol
frame or visibly changing status.

Payload maps contain exactly the keys below. A receipt id is the 22-byte
unpadded base64url encoding of 16 client-generated cryptographically random
bytes and is not a session id. All text is valid UTF-8. `lines` has at most 256
entries, each entry is at most 8 KiB, and the sum of the entries' UTF-8 byte
sizes (without separators or ETF overhead) is at most 48 KiB. A `:clear_live`
delta requires `lines: []`.

Daemon render output converts CRLF and LF into logical `lines` entries before
8-KiB chunking, preserves intentional blank lines, and rejects an expansion
above the 256-entry bound. The thin client applies the same CRLF/LF expansion
defensively to every received presentation, status, error, close, and
confirmation-prompt string. Bare CR, ESC, BEL, and every other C0/C1 terminal
control remain non-structural and render as U+FFFD; daemon text is never passed
through as ANSI. Presentation may be bounded by the existing display budget,
while an authority-bearing confirmation that cannot fit fails closed before
acknowledgement.

| Direction | Frame | Exact payload |
| --- | --- | --- |
| client → daemon | `:input` | `%{input_receipt_id: receipt_id, text: text}`; text is at most the existing Settings Central `channels.tui.max_text_bytes` value (default 12,000; bounded 1–32,000), reused as the TUI surface's inbound and rendered-text ceiling rather than adding a second setting |
| client → daemon | `:resize` | `%{columns: 1..500, rows: 1..200}` |
| client → daemon | `:cancel` | `%{reason: :operator_escape \| :operator_interrupt}` |
| client → daemon | `:confirmation` | `%{confirmation_id: id, decision: :approve \| :deny}`; id is 1–128 bytes |
| client → daemon | `:ack` | `%{}` |
| client → daemon | `:detach` | `%{reason: :operator_exit \| :eof}` |
| daemon → client | `:snapshot` | `%{render_revision: non_negative_integer, state: render_state, lines: lines, gap?: boolean}`; full replacement |
| daemon → client | `:delta` | `%{render_revision: positive_integer, mode: :append \| :replace_live \| :clear_live, lines: lines}` |
| daemon → client | `:status` | `%{render_revision: non_negative_integer, state: render_state, text: text, input_receipt_id: receipt_id_or_nil}`; text is at most 4 KiB |
| daemon → client | `:confirmation` | `%{confirmation_id: id, prompt: prompt, expires_at_unix_ms: non_negative_integer}`; prompt is at most 12 KiB |
| daemon → client | `:completion` | `%{input_receipt_id: receipt_id, outcome: terminal_outcome, duplicate?: boolean, result_ref: result_ref_or_nil, lines: lines}` |
| daemon → client | `:error` | `%{code: error_code, message: message, input_receipt_id: receipt_id_or_nil}`; message is at most 4 KiB |
| daemon → client | `:close` | `%{code: close_code, message: message}`; message is at most 1 KiB |

`render_state` is exactly one of `:idle`, `:thinking`, `:streaming`,
`:confirming`, `:coding`, `:background`, and `:error`. `terminal_outcome` is
exactly one of `:completed`, `:rejected`, `:failed`, and `:outcome_unknown`; a
duplicate returns the original safe outcome with `duplicate?: true`, not a new
synthetic result. Sequence, acknowledgement, render-revision, and expiry
integers use the bounded signed-64-bit range above. A non-nil `result_ref` is
an opaque UTF-8 reference of at most 256 bytes. Error codes are
`:invalid_input`, `:receipt_conflict`, `:receipt_key_unavailable`,
`:confirmation_rejected`, `:runtime_error`, and `:outcome_unknown`. Post-open
close codes are `:normal`,
`:client_detach`, `:daemon_shutdown`, `:protocol_error`, `:frame_too_large`,
`:sequence_error`, `:ack_error`, `:overflow`, and `:runtime_unavailable`.
Internal exception/action names are never turned into peer atoms; only these
stable codes and redacted bounded messages cross the socket.

The daemon's inbound admitted-work queue holds at most 32 frames and 256 KiB
encoded. Both socket readers use one-at-a-time activation so their mailboxes
are not unbounded second queues. Valid `:ack`, `:detach`, and `:cancel` controls
are handled immediately; one pending `:resize` slot keeps only the newest size
and counts toward the queue. Input and confirmation frames are never silently
dropped. The daemon's outbound unsent queue holds at most 64 frames and 256
KiB; its unacknowledged window holds at most 32 retained frames and 256 KiB.
The client renders one received frame before activating the next socket read;
its outbound unsent and unacknowledged queues each hold at most 32 frames and
256 KiB. At that limit it pauses terminal input, coalesces only resize, and
shows a local bounded backpressure status rather than dropping an input or
confirmation. Cancel and detach are attempted immediately; if a non-droppable
control cannot enter the bounded writer, the client closes the socket so the
daemon's attended-turn loss policy cancels safely.

Queue byte limits are encoded-envelope limits, not payload-only limits. Before
accepting local input custody or an unsent frame, the client charges a
conservative full-envelope bound using the frozen maximum counter widths; the
protocol still validates the exact encoded frame at send time. Reconnect replay
drains each admitted receipt incrementally, so a payload-only estimate or a
second aggregate replay queue cannot strand custody that the client already
accepted. At the frame/byte boundary the thin client stops requesting another
complete line until a receipt finishes; it does not consume and discard a 33rd
submission.

Before applying those limits, the client replaces its unsent resize and the
daemon's inbound queue likewise retains only its newest pending resize. The
daemon replaces an older unsent snapshot with the newest full snapshot.
Adjacent presentation-only statuses for the same render revision are
newest-wins. Adjacent same-revision deltas reduce deterministically: append +
append concatenates; a later replace or clear supersedes what precedes it;
replace + append remains replace with concatenated lines; and clear + append
becomes replace. A reduction that would exceed any frame/line bound is not
performed. Render revision is bounded presentation correlation, not an
authority token; v1 does not add a monotonic-revision close rule. If space is
still required, the daemon drops the oldest unsent
presentation-only `:status`, then the oldest unsent presentation-only `:delta`,
and schedules the next
presentation as a full `:snapshot` with `gap?: true`. It never drops an input
admission outcome, confirmation, completion, error, or close. If a
non-droppable frame cannot fit, the daemon makes one best-effort `:close` with
`:overflow` and closes the socket. Durable results remain inspectable after a
fresh open; transient presentation is not replayed.

Droppability follows queue priority and custody, not the frame tag alone. In
particular, a fan-out authority delivery may use a `:delta`, but its cumulative-
ack waiter makes it non-droppable and ineligible for gap absorption or adjacent
presentation reduction. A terminal close is likewise a queue barrier: after
applying the peer's cumulative ack, the session drains already-admitted
non-droppable frames in order, then emits close as the final frame. If the
remaining authority queue cannot drain within the bounded window, those
waiters fail rather than being reported delivered and the best-effort close is
`:overflow`.

Adding a key, frame, enum value, or relaxed interpretation requires a new
additive session-protocol version and an explicit compatibility row. It does
not alter kind-absent attach-v1.

### 3. Create the TUI adapter only after an authenticated open

Daemon application boot excludes `tui` from the ordinary static
`Channels.Supervisor` child specs. The attach listener and bounded session
owner start, but there is no registered TUI adapter before the first accepted
open. The session owner is a plain GenServer: it owns transport lifecycle and
bounded queues, and needs neither Jido skill composition nor action authority;
its module documentation records that substrate choice. After authentication,
socket control transfers to that monitored owner before post-open reads begin;
the accept loop immediately returns to accepting clients and never owns a
long-lived session or its queues.

Open is serialized in this order:

1. Validate the complete transport handshake, including token, canonical Home,
   uid, versions, and frame bounds. No identity bootstrap or adapter exists yet.
2. Atomically reserve the Home's sole provisional TUI slot. A competing open
   receives `:already_attached` without running bootstrap.
3. On the daemon side, normalize the requested profile and call the existing
   `IdentityBootstrap.prepare_local_launch/1`. Raw-absent identity may take the
   existing local bootstrap path; an explicit disabled/false mapping remains a
   denial. The verified operator returned by Settings Central, never the
   profile asserted by the client, becomes channel identity.
4. Start exactly one temporary (`restart: :temporary`)
   `AllbertAssist.Channels.TUI.Adapter` child under the existing
   `Channels.Supervisor`, with automatic local stdin disabled and its input/
   output bridged to the session owner. Only then accept the session.

Bootstrap or child-start failure releases the provisional reservation and
returns a bounded open error. Registration, child monitoring, and the atomic
reservation prevent duplicate adapters. Session close stops the transient
adapter, removes its subscriptions, and releases the reservation before a new
open can succeed. Daemon startup and session teardown tests assert that no
static or stale registered TUI adapter remains. If the invariant is already
violated, open fails closed as `:already_attached`; it never starts a second
adapter. The terminal client starts no adapter at all.

### 4. Extend inbound channel events for conservative input receipts

The receipt seam extends the existing `channel_events` inbound dedupe row and
its existing `(channel, external_event_id)` uniqueness. Receipt rows use
`channel: "tui"`, `provider: "terminal"`, and `direction: "inbound"`. The
provider class/trust class remains local; it is not the event provider. This does
not add a table, receipt server, or private durable goal loop. Additive nullable
fields record
`receipt_normalizer_version`, `receipt_hmac_key_ref`,
`receipt_hmac_key_version`, `receipt_payload_hmac`, `receipt_state`,
`receipt_message_id`, `receipt_result_ref`, and `receipt_outcome`; existing
`input_signal_id`, `thread_id`, and `trace_id` carry their current references.
No raw input, command output, token, or terminal frame is copied into the receipt
fields.

For every `:input`, before deciding whether text is a slash command, ordinary
turn, or coding correction, the daemon applies `tui-input-v1`: require valid
UTF-8, convert CRLF and lone CR to LF, trim the same leading/trailing Unicode
whitespace as the existing TUI adapter, reject empty/oversized input, and
preserve all remaining content exactly. The normalized profile is the Settings
Central profile used for the verified local operator.

Fields are encoded as a length-prefixed byte sequence and base64url is
unpadded. The stable row namespace does not depend on key rotation:

- `external_event_id = "tui:r1:" <> base64url(SHA256(encode("tui",
  verified_operator_id, normalized_profile, input_receipt_id)))`.

Through the additive system-owned namespace on existing Settings Secrets/Key
Custody, the daemon causes one 32-byte per-Home HMAC key to be serialized-
fetched-or-created at `secret://system/integrity_v1` (record version `1`) before
first admission. The one non-process system-integrity helper inside that
existing concern derives
`domain_key = HMAC-SHA256(home_hmac_key, UTF8(domain_string))`, then HMACs a
canonical length-prefixed payload with the domain key. Consumers receive only
the tag/verification result, never the raw Home key. For TUI it uses domain
`allbert.tui.receipt-payload.v1` and stores
the non-secret reference/version and computes:

- `receipt_payload_hmac = base64url(HMAC-SHA256(domain_key,
  encode("tui-input-v1", normalized_text)))`.

The additive callable seam is
`KeyCustody.system_hmac(domain, fields, key_version)` returning tag plus the
fixed non-secret ref/version, and
`KeyCustody.verify_system_hmac(domain, fields, tag, key_ref, key_version)`.
`fields` is a versioned ordered list encoded by the helper; domain consumers do
not supply an already-concatenated byte string. The private
`fetch_or_create_system(ref, byte_count)` primitive is used only inside those
operations.

The additive `fetch_or_create_system/2` path accepts only that closed ref in
this milestone, generates exactly 32 random bytes for a genuinely fresh Home,
commits it through the existing encrypted Settings store before returning, and
never returns it through ordinary settings/status rendering. Concurrent first
calls serialize on Key Custody and receive the same material. v1.3 may reuse
the ref through separately fixed Memory/Search/delete-preview domains; it does
not add more per-purpose Home secrets.

The secret stays in the established encrypted/system-secret path; this ADR does
not add a key manager or rotation workflow. The selected v1 key is stable for
this milestone. A missing/unavailable referenced version fails input admission
closed and never silently mints a replacement over existing receipts; a future
rotation must retain old verification versions while their receipt rows remain.
The namespace prevents the same client receipt id from colliding across
verified operators or profiles, while the keyed normalized payload digest
detects reuse with different text without storing that text in transport
metadata.

Receipt states are exactly `received`, `admitted`, `in_progress`, `completed`,
`rejected`, `failed`, and `outcome_unknown`. Handling is:

Every receipt insert/load and state transition claims SQLite's writer slot with
a per-transaction `:immediate` mode before its read-to-write decision. Receipt
correctness therefore does not depend on the operator/test Repo pool topology,
and a deferred-transaction upgrade cannot turn an admitted burst into
`SQLITE_BUSY`; this does not change the global Repo configuration.

1. Insert or load the inbound `channel_events` row in a transaction and compare
   the payload HMAC in constant time. A mismatch returns `:receipt_conflict`
   and performs no classification or dispatch.
2. For a new row, commit `received`, then commit `admitted` and the available
   signal/thread/trace identifiers before handing normalized input to the
   existing TUI adapter. The adapter classifies and dispatches slash, ordinary-
   turn, or correction work through the existing action/runtime spine; a
   rejected handoff is terminalized as failed. Move to `in_progress` when
   execution starts. This more-conservative landed ordering never exposes an
   unrecorded classification/dispatch window.
3. Persist a safe terminal outcome plus message/result references as
   `completed`, `rejected`, or `failed`. A duplicate terminal receipt returns
   those safe references with `duplicate?: true`; it does not dispatch again.
4. A duplicate non-terminal receipt owned by a demonstrably live session,
   action, or objective returns observable in-progress status and does not
   dispatch again.
5. After daemon restart, reconcile a non-terminal receipt to an existing
   durable terminal result when exact stored references prove one. Otherwise
   an orphan `received`, `admitted`, or `in_progress` receipt becomes
   `outcome_unknown`. It is never automatically re-executed. The client tells
   the operator the result is uncertain; deliberate retry creates a new receipt
   id and therefore a visibly new execution attempt.

This ordering closes the current slash-command hole in inbound dedupe and gives
normal turns and corrections the same seam. It provides durable duplicate
suppression and honest uncertainty, not atomic exactly-once coupling across
SQLite, signals, providers, and external effects.

The client keeps at most its bounded outstanding receipt ids and normalized
payloads in memory. After an ambiguous close it restores the TTY first, then in
canonical mode offers one operator-triggered fresh attach attempt in the same
client invocation or exit; it does not run a background reconnect loop. A
successful fresh open may resubmit each pending id with the same payload once
to obtain the existing terminal/running/unknown response. Resubmission is never
permission to execute an uncertain result. The client writes no receipt
database or sidecar file. A later process creates a new id for new operator
input.

### 5. One active TUI session per Home, with explicit reconnect

Exactly one TUI attachment may own the terminal-channel session for a Home at a
time. A second client receives a bounded busy response; Web, messaging, and
one-shot CLI surfaces remain usable through the same daemon. This is a
deliberate first implementation bound, not a claim that the protocol can never
support multiple terminal profiles.

There is no live-session resume in this milestone. Socket loss, client exit, or
daemon close ends the attachment and tears down its transient input/render
state. A fresh authenticated open may render durable conversation, objective,
confirmation, job, and receipt state through ordinary daemon reads; it does not
resume a partially rendered frame stream or reuse session sequence state.

### 6. Failure is fail-closed for attachment and safe for the terminal

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

The client installs its own handled-signal hooks and uses one idempotent
`try`/`after`-style restoration path to restore canonical terminal mode and
clear its transient live region on normal detach, `/quit`, authentication/
session error, overflow, detected socket loss, daemon shutdown, and handled
termination signals. On loss, the daemon can only close/release the session and
adapter; it cannot repair another process's TTY. SIGKILL, power loss, or
terminal-emulator failure cannot run client cleanup. Operator diagnostics
document `stty sane` and `reset` recovery; this milestone does not add a
watchdog solely for uncatchable termination.

The client installs that cleanup path before its first TTY mutation, remains in
canonical mode throughout handshake, and enters raw/alternate-screen mode only
after validating the accepted session's initial snapshot. A partial setup
failure runs the same restoration path. The packaged `allbert tui` dispatcher
scopes OTP's documented `+Bc` emulator posture to the thin-client VM so Ctrl-C
is delivered to the raw input reader. In `:thinking`, `:streaming`,
`:confirming`, or `:coding` state, or while the client still holds an unresolved
input receipt, it follows the `:operator_interrupt` cancel-then-detach path. An
idle, error, or durable-background client with no unresolved input detaches
without manufacturing a cancellation. It appends the flag without discarding
existing emulator flags and does not change the daemon's signal posture.
Source-checkout PTY and attended runners apply the same TUI-child-only posture.
This uses the supported launcher boundary rather than private `:prim_tty`
terminal-mode mutation, a platform-specific `stty` subprocess, or a second
signal implementation.

### 7. Presentation and authority remain on existing spines

The daemon emits bounded typed surface payload/render frames; only canonical
model payload enters conversation memory under ADR 0067. Confirmations,
operator reads, ordinary turns, Pi actions, and cancellations still route
through the registered action/runtime boundaries. Session frames carry input
and presentation; they do not constitute a new capability or permission path.

Trace/audit records contain session lifecycle and trace-safe receipt metadata,
not raw attach tokens, input, HMAC keys, or terminal-frame payloads. Input
execution remains on the existing inbound/action boundaries; the additive
receipt row returns a prior safe result or explicit uncertainty rather than
granting authority or promising exactly-once execution.

Erlang's `binary_to_term/2` `:safe` option prevents creation of new atoms and
other unsafe term classes, but it is not a schema, depth, allocation, or
application-authority check. ETF also defines a compressed term tag. That is
why v1 combines the existing encoded-body cap with a pre-decode compression
ban and post-decode exact structural validation
([Erlang `binary_to_term/2`](https://www.erlang.org/doc/apps/erts/erlang.html#binary_to_term/2),
[External Term Format](https://www.erlang.org/doc/apps/erts/erl_ext_dist.html)).

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

Acceptance requires focused protocol/security tests for kind-absent attach-v1
compatibility; every open rejection code; compressed ETF, exact-key/type/enum,
nesting/map/list/text/frame limits; independent directional sequencing and ack
validation; and every client and daemon frame. Queue tests hit each coalescing
rule, both byte and count high-water marks, the status-then-delta drop order,
the `gap?: true` replacement snapshot, preservation of non-droppable frames,
and terminal `:overflow` close.

Lifecycle tests prove daemon boot has no TUI adapter, unauthenticated or denied
open never runs `IdentityBootstrap`, two racing opens produce only one adapter,
raw-absent versus explicit-false identity behavior is preserved, and every
close/failure removes the transient child and reservation. Receipt tests cover
slash commands, ordinary turns, and coding corrections before dispatch;
terminal duplicate return; conflicting normalized payload denial; live
in-progress observation; daemon-restart reconciliation; and mandatory
`outcome_unknown` with no automatic re-execution when no terminal result is
provable. They also prove receipt fields contain no raw input/result.

Focused behavior rows cover detach/socket-loss cleanup, one-session capacity,
Pi cancellation, durable background completion, confirmation handoff, and
client-owned terminal restoration on every handled exit.

Packaged macOS and Linux validation starts the service first, keeps it running
before/during/after TUI use, proves the TUI process opens no Repo or migration,
uses Web and TUI concurrently against the same conversation/runtime, exercises
fan-out and Escape cancellation, kills each side of the socket, and verifies
the terminal and service health after every handled failure. A separate
uncatchable-client-termination row proves the documented `stty sane`/`reset`
recovery without claiming in-process cleanup.

M0.b2 focused evidence covers the daemon protocol/session queue, integrity,
receipt, Adapter, confirmation, fan-out, and teardown rows. The operator-
attended warm thin-client run and exact packaged-artifact TTY rows are
mandatory M0.b3/M0.c3 evidence; automated PTY coverage supports but does not
replace those release barriers.
