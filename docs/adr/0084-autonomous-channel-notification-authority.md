# ADR 0084: Autonomous Channel Notification Authority

## Status

Proposed (v1.1 planning, 2026-07-18). Binding on v1.1 M6/M7 once Accepted;
Accepted in M7 only after `Channels.Notify`, defaults-OFF settings, the
restart-safe delivery ledger/edit path, redacted markdown audit, and focused
authority proofs land together. Gate-bound `:v11` eval rows follow at M10.
This is a security ADR defining a NEW authority class.

## Context

Until v1.1, Allbert sends a message on a remote channel in exactly two ways:

1. **As a turn response** — the reply to an inbound message, delivered on the
   same blocking call path the user just exercised. The user is, by
   construction, present and expecting it.
2. **As an operator-initiated compose** — `send_channel_message` (ADR 0063),
   which is identity-allowlist-gated and `confirmation: :required`
   (`actions/channels/send_channel_message.ex:17,:149-160`) before it reaches
   the single `Channels.Outbound.send/4` boundary
   (`channels/outbound.ex:24-42`).

There is NO path by which the runtime, on its own initiative, sends anything
to anyone. The v0.55 parity matrix makes this posture explicit by pinning
`streaming: "turn_complete"` for every channel
(`channels/channel_parity.ex:98` — "until a later ADR changes that contract";
this is that ADR).

The v1.1 fan-out flagship (ADR 0083) creates work that outlives the turn.
Status updates, completion reports, and background-raised confirmation
requests have no delivery path: objectives carry
`source_channel`/`source_surface` attribution (`objectives/objective.ex:21-22`,
v1.0.1) but nothing consumes them; `Confirmations.Origin` carries a
`response_target` (`confirmations/origin.ex:29`) with no out-of-band delivery
consumer — only the approval-side plumbing exists
(`channels/confirmation_callback.ex` typed commands, channel buttons).

An unattended machine-initiated message to a human's phone/inbox/workspace is
a qualitatively different act from replying: it can spam, it can exfiltrate
(a prompt-injected "status" containing secrets), it can social-engineer (a
forged "approve this" ping), and it can leak presence/activity to anyone with
access to the receiving account. It therefore cannot ride the turn-response
path's implicit authority, and it must not be conflated with ADR 0063's
operator-initiated compose (which stays confirmation-gated per send —
unacceptable UX for automatic status, and the wrong actor model: notify is
runtime-initiated).

Security Central is the authority boundary (AGENTS.md); operator-tunable
configuration belongs in Settings Central; model output and metadata never
grant permission. A new authority class needs: an explicit grant surface,
defaults that deny, one enforcement chokepoint, an audit trail, redaction,
and gate-bound abuse-case coverage.

## Decision

0. **Consent may be granted in-channel exactly once, via typed command.**
   (Operator readiness-audit addition, 2026-07-18.) A channel's FIRST fan-out
   kickoff ack may append a ONE-TIME offer — `ALLBERT:NOTIFY:ON` (buttons
   where the channel has them). Accepting writes
   `channels.<id>.autonomous_notify.enabled=true` through the standard
   audited settings path with channel-identity re-proof (the
   `ConfirmationCallback` typed-command family); dismissal or any answer
   retires the offer durably (per-channel offered marker) — it never
   repeats. Free text NEVER changes the setting; only the typed
   command/button path does. This is a consent-capture affordance, not a
   second authority path: the setting it writes is the same one, with the
   same audit row, as a Settings Central edit.

1. **Autonomous channel notification is a distinct authority class**, granted
   ONLY by per-channel operator settings in Settings Central and enforced at
   ONE boundary, `AllbertAssist.Channels.Notify`. No other module may
   initiate an unattended transport send. `Channels.Outbound` remains the
   transport dispatch; `Notify` is the authority gate in front of it for
   runtime-initiated sends, exactly as the ADR 0063 action is the gate for
   operator-initiated sends. Adapters gain no new authority; they keep the
   dumb `deliver_outbound/3` transport callback.
2. **Settings keys, defaults OFF.** Schema fragments (ADR 0031) per
   registered channel:
   - `channels.<id>.autonomous_notify.enabled` — boolean, **default
     `false`**. Absent/false means: zero autonomous sends on that channel,
     ever, regardless of any other state.
   - `channels.<id>.autonomous_notify.level` — enum `"completion"` |
     `"status_and_completion"`, default `"completion"`. Email is clamped to
     `"completion"` (digest-class medium; schema rejects the higher level).
   - `channels.<id>.autonomous_notify.min_interval_seconds` — integer,
     default 30, clamp 5..600; the coalescing/throttle window for status
     kinds.
   Notification kinds: `:status`, `:completion`, `:confirmation_request`.
   `:confirmation_request` and `:completion` are governed by `enabled` alone;
   `:status` additionally requires the higher level. There is no global
   enable — the grant is per channel, deliberately.
3. **The enforcement chain runs in order, fail-closed, at send time:**
   (a) channel live-use allowed (`ReleaseAvailability` — unreleased channels
   cannot be notified even if enabled); (b) `enabled` true; (c) kind
   permitted by `level`; (d) throttle/coalescing window respected; (e)
   Security Central policy consult (the class is deniable by policy
   independent of settings); (f) target re-derivation: the transport target
   is derived at send time from the channel identity map plus the
   objective's origin (`source_channel` + recorded channel thread refs) —
   **stored free text, model output, and action params are never an
   address**. A target that does not resolve to the objective owner's mapped
   identity on the origin channel is denied. Every decision — delivered,
   suppressed (with reason), failed — emits
   `allbert.channels.notify.{delivered,suppressed,failed,uncertain}`.
   Operational state
   is persisted in an additive delivery ledger; redacted append-only operator
   evidence is written through `Runtime.Audit :channel_notify` to monthly
   files at `<ALLBERT_HOME>/channels/notify/audit/YYYY-MM.md`; the matching
   `Paths` resolver and `ensure_home!/0` entry own the directory. Where the
   channel descriptor declares
   `status_update_mode: :edit_in_place` (v1.1 M7, plan Locked Decision 11),
   `:status` delivery maintains ONE status message per fan-out per channel
   and edits it in place; an edit IS a delivery for the throttle window
   (edits cannot evade (d)), edit failure falls back to an audited append,
   and `:completion`/`:confirmation_request` kinds are ALWAYS new messages —
   an approval prompt never replaces history.
   The ledger persists local user/channel/origin identity, provider message
   id, throttle timestamp, terminal-event idempotency key,
   attempt/error class, and one-time-offer state, but never payload text,
   secrets, raw external identity, or free-text addresses. Restart
   resumes editing the same status message; append fallback replaces its id.
   If provider acceptance is possible but no receipt persisted, state becomes
   `uncertain`: autonomous retry is suppressed and the durable report falls
   back to status/next-turn retrieval with an audit warning.
4. **Redaction is mandatory.** All notify payloads (status summaries,
   completion reports, confirmation prompts) pass `Security.Redactor` before
   rendering; secrets/vault material never appear in transport payloads,
   logs, audit rows, or release evidence. Confirmation-request notifications
   carry the confirmation id and a redacted description — never the raw
   params.
5. **Approval never rides the notification.** A `:confirmation_request`
   notification renders the channel's existing approval primitives (inline
   buttons where supported, typed `ALLBERT:APPROVE|DENY|SHOW:<id>`
   everywhere); resolution flows ONLY through the existing
   `ConfirmationCallback` path with its identity re-proof
   (`confirmation_callback.ex:21-33`). Free-text replies — including replies
   classified as steering — never approve. The notification is a pointer, not
   a grant surface.
6. **The attended-surface boundary.** Push rendering to an ATTACHED live
   local surface — an open workspace LiveView session (SignalBridge PubSub)
   or an attached TUI TTY session — is NOT autonomous notification: the user
   is present, the delivery is session-scoped, and no unattended transport
   send occurs. The class covers transport sends to remote channel
   identities (telegram/email/discord/slack/matrix/whatsapp/signal) and any
   future unattended medium. Next-turn report delivery (`pending_reports` in
   the turn response) is likewise a turn response, not an autonomous send.
   This line is what lets the default stay OFF without making fan-out
   useless.
   The fan-out kickoff is also a turn response, but ADR 0083 makes its
   successful delivery—or the public protocol's specified durable
   equivalent—an execution precondition: framing returns a start receipt and
   no child runs until the originating caller acknowledges the rendered,
   transported, printed, or durably recorded kickoff. Non-streaming HTTP uses
   durable server-side recording; SSE uses successful kickoff-event flush.
   A delivery failure leaves the fan-out blocked; it cannot be reclassified
   as autonomous notify and cannot trigger background execution.
7. **The parity contract is renegotiated, additively.** Channel descriptors
   gain an optional `streaming:` capability field
   (`:turn_complete | :progress_messages | :live_region`, absent =
   `:turn_complete`); `ChannelParity` derives the streaming column from
   declarations instead of the `:98` hardcode and validates that
   `:live_region` is declared only by local surfaces. v1.1 M7 adds a second
   additive capability field on the same pattern —
   `status_update_mode: :append_only | :edit_in_place`, absent =
   `:append_only`; telegram/discord/slack/matrix declare `:edit_in_place`.
   Capability
   (`streaming:`, `status_update_mode:`) and authority
   (`autonomous_notify.*`) are independent axes:
   a channel can be capable but ungranted (the default), and a grant on an
   incapable kind is inert.

### Abuse cases and their controls

| Abuse case | Control |
|---|---|
| Prompt-injected task output triggers notification spam | kinds are runtime-defined (model output cannot mint sends); throttle/coalescing per fan-out; default OFF |
| Exfiltration via status text (secrets in a "summary" to a channel an attacker watches) | mandatory redaction (4); target re-derivation to the owner's mapped identity only (3f); audit trail |
| Social-engineered approval ("reply yes to approve") | approval only via typed-command/button `ConfirmationCallback` with identity re-proof (5); gate-bound eval row `fanout-steer-no-approve-001` |
| Cross-user leak (report delivered to a different account/thread) | origin-bound target derivation (3f); identity map is the only address book; eval row `fanout-notify-cross-user-001` |
| Silent scope creep (new code sending via adapters directly) | single boundary (1); adapters' `deliver_outbound/3` reachable only via `Channels.Outbound` (operator class) or `Channels.Notify` (this class); review rule recorded here + parity `outbound` column stays honest |
| Unreleased-channel probing (whatsapp/signal) | `ReleaseAvailability` check first (3a) |
| Notification flooding after failures | bounded retry (one, post-interval), then suppress-with-reason; report falls back to next-turn delivery — failure never loops |
| Replay/duplication of a completion report | delivery-ledger unique key per (fanout, kind, terminal transition); uncertain sends suppress autonomous retry and retain next-turn fallback |

## Consequences

- Operators get real background report-back with a one-setting-per-channel
  opt-in and a hard default of silence. The out-of-the-box posture is
  unchanged: Allbert never messages first.
- One new chokepoint to maintain — every future proactive feature (1.4
  proactive notifications ride here) inherits the grant surface, audit, and
  redaction for free instead of inventing its own.
- Two adapters change shape to honor the all-channels rollout: email
  implements `deliver_outbound/3` (closing its ADR 0063 gap as a side
  effect), signal's daemon receiver gets wired (ADR 0058 pattern). Neither
  changes its release-availability status.
- `send_channel_message` (ADR 0063) is untouched: operator-initiated compose
  keeps per-send confirmation. Two classes, one transport.
- The `streaming: "turn_complete"` era ends; parity rows become declarations
  and the v0.55 moduledoc's "until a later ADR" clause is discharged.
- A permanent review obligation: any new call path to `deliver_outbound/3`
  must name its authority class (0063 or 0084) or be rejected.

## Validation

- v1.1 M6: the notify authority suite — default-off suppression (zero
  transport calls on fixture adapters), per-kind/level matrix, throttle and
  coalescing, cross-user denial, unreleased-channel denial, redaction
  asserts, audit-row completeness — green; per-adapter outbound unit suites
  on fixture transports; additive ledger migration round-trip from a pre-M6
  database plus delivery-ledger and monthly markdown-audit persistence
  proven; ADR remains Proposed pending edit/restart proof.
- v1.1 M7: the edit-in-place delivery suite — one status message edited per
  fan-out on the four declaring channels' fixture transports, audited
  append fallback on edit failure, completion/confirmation never edited,
  edits throttle-counted, restart resumes the same message id, uncertain
  sends suppress retry — green. ADR flips Accepted here.
- v1.1 M10: `:v11` eval rows bound into `release.v11`
  (`fanout-notify-default-off-001`, `fanout-notify-cross-user-001`,
  `fanout-notify-redaction-001`, `fanout-steer-no-approve-001`,
  `fanout-notify-consent-free-text-001` — the Decision 0 control — at
  minimum).
- v1.1 M12: per-channel operator validation matrix
  (`docs/plans/v1.1-request-flow.md` §J) — notify OFF silence and notify ON
  behavior attested live on every released, operator-configured channel.
  Full simulated end-to-end evidence is mandatory for WhatsApp/Signal while
  ReleaseAvailability-gated; their live row becomes mandatory only when
  released and configured. `release.v1` is green at the tag.
