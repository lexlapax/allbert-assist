# ADR 0068: Pi-mode Coding Surface and Local-Coding Trust Tier

Status: Proposed (v0.57).
Date: 2026-06-21
Related: ADR 0067 (TUI/terminal channel + split tool result — the foundation
this surface streams over), ADR 0009 (local execution sandbox levels — the
**level** reference; the local-coding tier runs at **Level 1**, not Level 0),
ADR 0056 (channel inbound trust tier — the **trust-tier** lineage the
local-coding tier extends), ADR 0016 (channel adapter boundary — the coding
surface is a channel/app, not a second runtime), ADR 0006 (Security Central —
unchanged), ADR 0029 (typed response contracts — split payload). Precedent for
host shell execution: `run_shell_command` (ADR 0009 Level 1; explicit
executable/argv, no shell strings) and `plan_shell_command` (inert).
Predecessor/foundation: ADR 0067 (split result + terminal channel), ADR 0009
(sandbox levels), ADR 0056 (trust tier), ADR 0016 (channel contract).
Rationale source: `docs/archives/pi-integration-rethink.md`.

## Context

The v0.55 terminal channel (ADR 0067) makes a real, identity-mapped terminal
surface available with a **static** split `model_payload` / `surface_payload`
contract (a complete `surface_payload` render; no incremental/streaming path —
that live-region substrate is net-new v0.57 work). That opens a concrete question
the rethink in
`docs/archives/pi-integration-rethink.md` raises: can Allbert host a focused
terminal **coding** surface — read/write/edit files and run shell — without
becoming a second authority spine, and without adopting the "YOLO, auto-approve
everything, let the model decide when it's done" posture that off-the-shelf
terminal coding agents default to?

The constraints are firm. Allbert has **one** authority spine: every effectful
operation goes through `Actions.Runner.run/3`, the action boundary, Security
Central (ADR 0006), and confirmations. Sandbox levels (ADR 0009) define the
isolation posture, and the project is MCP-first for external capability. A coding
surface that bypassed any of these would be exactly the "second runtime / second
security policy" the channel contract (ADR 0016) exists to prevent.

A coding loop also has a failure mode generic channels do not: the model deciding
on its own that effectful or generated-code work is "done." For effectful and
generated-code work that judgement must be **deterministic**, not model-asserted.

## Decision

### Pi-mode coding surface as a channel/app on the one authority spine

Introduce **Pi-mode**, a gated terminal coding surface implemented as a
channel/app on the existing terminal channel (ADR 0067) — **not** a new runtime
or a new authority path. Its default capability is **six tools** — three
read-only/sensitive tools plus three effectful tools — each a registered action
invoked through `Actions.Runner.run/3`:

- **read** — read file/context (chunked by default, offset/limit; permission
  atom `:coding_file_read`; see the context discipline below);
- **grep** — search file contents (ripgrep-backed or equivalent, `.gitignore`-
  aware; permission atom `:coding_file_read`, no confirmation prompt);
- **glob** — find files by path pattern (permission atom `:coding_file_read`, no
  confirmation prompt);
- **write** — create a file (permission atom `:coding_file_write`);
- **edit** — modify an existing file (permission atom `:coding_file_write`;
  exact-match replacement; an exact-match miss
  returns a clear failure so the model re-reads and retries, rather than a silent
  no-op — the most common friction in peer coding agents);
- **bash** — run a shell command at **sandbox Level 1** (ADR 0009), under the
  local-coding tier policy defined below (permission atom
  `:coding_shell_execute`).

`grep`/`glob` are first-class because relegating code search to MCP would feel
impoverished to Claude Code / Gemini users (2 of the 3 peer CLIs ship them
built-in). Capabilities **beyond** these six remain MCP-first, lazy-disclosed.
Read/search actions run without a confirmation prompt, but they still pass
Runner/Security Central and enforce cwd jail, symlink policy, ignore policy,
output caps, redaction, trace, and audit. Dotted values such as
`permissions.coding_file_read` are Settings Central keys, not permission atoms.

Surface discipline:

- a **sub-1000-token surface budget** — the coding system prompt **and the tool
  definitions together** stay under ~1000 tokens (Pi's actual bar is
  prompt + tool-defs combined, against the configured tokenizer), not a sprawling
  agent harness;
- **streamed split-payload diffs + assistant-text token streaming** — the
  model-facing `model_payload` carries the canonical change while the terminal
  renders the `surface_payload` diff. v0.55 shipped only the **static** split;
  **v0.57 builds the coding-diff live-region renderer, the progressive
  tool-argument streaming** (parse tool-call arguments as they arrive), **and
  token-by-token streaming of the assistant's prose** — so the turn feels live, as
  in every peer CLI. Token streaming requires the runtime to emit model token
  deltas (today's response is turn-complete); the diff streamed unit is the
  tool-call argument stream, not the tool result;
- **interactive affordances** — **coder-facing approval modes**
  (`default`/`accept-edits`/`plan`/`tier`) implemented as a **confirmation-cost seam**
  in `Security.Decision` (drops only the prompt; preserves the `:needs_confirmation`
  decision, policy, trace, and audit; grants no authority; `plan` executes
  read/search only), with "always allow this command" reusing the existing
  `Resources.Grants` remembered-grant lifecycle (not a parallel allowlist);
  **Esc-to-cancel** a running turn — which requires running the turn under a
  supervised Task (the synchronous v0.55 runtime cannot cancel mid-turn) — with a
  **queued correction**; and a familiar coding **slash set**
  (`/help`, `/model`, `/clear`, `/init`, `/diff`, `/compact`);
- **context discipline (Pi's actual practice)** — gather context through
  **chunked reads** (offset/limit) and, for larger investigations,
  **separate context-gathering sessions plus file artifacts**, rather than always
  ingesting whole files. (Earlier drafts claimed a "full-file context" philosophy
  and attributed it to Pi; Pi reads in bounded chunks by default and notes models
  resist full reads. The discipline is deliberate context gathering, not
  whole-file ingestion.)

Every one of the six tools is an ordinary registered action: it passes the action
boundary, Security Central, and its own policy/confirmation gate. `read`/`grep`/
`glob` are read-only/sensitive and run without a confirmation prompt; `write`/
`edit`/`bash` are effectful. The surface selects and sequences; it grants no
authority.

The coding slash set is slash-allowlisted and non-routable, but not a hidden
effect path. `/help` is router-local; `/diff` and `@file` use
`:coding_file_read`; `/init` writes through `:coding_file_write`. `/model`,
`/clear`, and `/compact` are **ungated session/model ops** — in-memory controls
with no persistent or external effect, so they carry **no permission atom** (there
is no `:coding_session_write`; permission-gating an in-memory `/clear` would be
prompt-fatigue ceremony no peer CLI imposes).

**The interactive turn vs. "done."** Like Claude Code / Codex / Gemini, the
ordinary turn is an interactive REPL: the model loops (propose tool calls → read
results → repeat) and the **turn ends naturally when the model stops emitting tool
calls**, returning control to the operator prompt. The separate rule — "the model
never decides it is *done*" — governs **deterministic acceptance gates** for
effectful or generated-code work (evidence + confirmation), not the end of a
conversational turn. Implementers must not gate every turn-end; that would feel
alien to a coder.

### Named "local-coding operator" trust tier (extends ADR 0056; runs at sandbox Level 1)

Add a named trust tier — **local-coding operator** — extending the channel
trust-tier convention (ADR 0056). It is scoped to **a single trusted operator in
the main session on the terminal channel**: the local human driving Pi-mode
interactively. It is a named, explicit tier so the trust assumption is legible
and auditable, not an implicit relaxation buried in the coding surface.

**Level vs. tier.** This tier is *not* a sandbox level and is *not* "sandbox
level 0". `bash` runs host processes, which is **sandbox Level 1** (ADR 0009) —
Level 0 is inert planning with no execution. The tier modulates only the
*confirmation burden* at Level 1: for the trusted local caller the gate is
**present but cheap** (no per-action confirmation prompt) while policy,
redaction, trace, and audit **still run** at Level 1. (Earlier drafts named this
"local coding / sandbox level 0"; that label is superseded — see the ADR 0009
v0.57 clarification.)

**The `bash` policy at the local-coding tier.** Unlike the general-purpose
`run_shell_command` action (ADR 0009 Level 1), which forbids shell strings and
takes an explicit executable + argv, Pi-mode `bash` accepts **raw shell command
strings** — but **only** when the local-coding operator tier resolves (trusted
operator, main session, `tui`). For every other caller `bash` is unavailable or
falls back to the argv-only `run_shell_command` posture. Raw-shell at the tier is
bounded by:

- **cwd confinement** to the working repo root;
- a **wall-clock timeout + brutal-kill** (reuse the `skill_script_runner`
  execution discipline);
- **full trace + audit** and redacted/truncated `channel_events` summaries;
- the explicit stance, inherited from Pi, that **the host (or a container the
  operator runs Allbert in) is the security boundary — OTP/BEAM supervision is
  not**.

This is a deliberate, tier-restricted superset of `run_shell_command`'s
anti-injection posture: arbitrary shell is acceptable here precisely because the
caller is a single trusted operator typing at their own terminal, and is refused
everywhere else. The trade-off (raw shell vs. argv-only) is recorded as a locked
decision in the v0.57 plan.

## Non-goals and guardrails

- **Never YOLO-by-default.** Pi-mode does not auto-approve effectful actions and
  is not enabled by default.
- **Never for channel-originated or generated-code sessions.** The local-coding
  tier applies only to the single trusted operator in the main terminal session.
  It never extends to channel-originated requests or to generated-code execution
  sessions, which keep their existing tiers. In particular, raw-shell `bash` is
  reachable only at this tier; every other caller is argv-only or refused.
- **No weakening of the action boundary, Security Central, or confirmations.**
  All six tools run through `Actions.Runner.run/3` and Security Central
  (ADR 0006) exactly like any other action; approval modes and "always allow"
  change only confirmation cost, never the authority path; confirmation gates are
  unchanged.
- **The model never decides it is "done"** for effectful or generated-code work.
  Acceptance is governed by **deterministic acceptance rules**, not the model's
  self-assessment.
- **Keep MCP-first.** Pi-mode does not displace the MCP-first posture for
  external capability; it is a focused local surface over the existing boundary.

## Consequences

- Allbert gains a focused terminal coding surface that lives entirely on the one
  authority spine: six registered coding actions, no second runtime, no second
  security policy.
- A named **local-coding operator** trust tier (ADR 0056 lineage, running at
  ADR 0009 **Level 1**) makes the single trusted-operator assumption explicit and
  auditable, and bounds it to the main terminal session. It is not a new sandbox
  level and never "level 0".
- The guardrails preserve every existing invariant: action boundary, Security
  Central, confirmations, sandbox levels, and MCP-first are unchanged; read/search
  is policy-bounded even when unprompted; "done" for effectful/generated-code work
  is deterministic, not model-asserted.
- This surface depends on the v0.55 terminal channel and **static** split-result
  pattern (ADR 0067). The **streaming** half — the coding diff live-region
  renderer and progressive tool-argument rendering — is **net-new v0.57 work**,
  not a v0.55 inheritance; v0.55 ships no incremental render path.
- Raw-shell `bash` widens the host-execution surface relative to
  `run_shell_command`. The exposure is bounded by the tier (single trusted local
  operator only), cwd confinement, timeout, and audit; the security boundary is
  the host/container, not OTP.
- **Clean mid-turn cancellation requires net-new runtime work.** The v0.55 runtime
  executes a turn **synchronously and blocking** (no handle to an in-flight turn),
  so Esc-to-cancel is impossible without first running a coding turn's model call
  under a **supervised Task**. This async turn-execution boundary is its own
  milestone and the prerequisite for real cancellation (abort the in-flight
  `ReqLLM.StreamResponse`, not merely abandon it).
- **The "cheap gate" is a confirmation-cost seam, not an authority change.** It is
  implemented in `Security.Decision.build/1`: when the tier/mode resolves it sets
  `requires_confirmation: false` while preserving the `:needs_confirmation`
  decision, policy, risk, trace, and audit. The decision and the audit trail are
  unchanged; only the interactive prompt is suppressed.
- **"Always allow" reuses `Resources.Grants`,** the existing durable, scoped,
  expirable, revocable, audited remembered-approval lifecycle — a command-scoped
  grant keyed by repo fingerprint + permission + cwd + canonical (normalized,
  redacted) command — rather than a second allowlist subsystem.
- **Coding tool I/O is session-scoped.** Reads, searches, diffs, and shell output
  stay in the session trace; they are not auto-promoted to markdown-first long-term
  memory unless the operator explicitly saves them.
