# Pi vs. Allbert — Rewrite or Incorporate?

*Comparison + integration recommendation. Written to sit next to `docs/archives/project-direction-rethink-01.md` and could become an ADR or `docs/archives/pi-integration-rethink.md`. Grounded in the repo at `v0.54.0`, 64 ADRs, the Jido vision, and the existing Hermes/OpenClaw comparison.*

> **Supersession note (v0.57 second-pass readiness, 2026-06-23):** This archive
> is historical rationale, not current implementation or operator authority.
> Active v0.57 docs supersede this file's references to "sandbox level 0",
> "local coding / level 0", "full-file context", and "full-file-read". The
> current contract is: local-coding operator is a named trust tier, not a sandbox
> level, and it runs at ADR 0009 Level 1; Pi-mode context discipline is chunked
> reads (offset/limit) plus artifacts, not whole-file ingestion. Use ADR 0009,
> ADR 0068, `docs/plans/archives/v0.57-plan.md`, and
> `docs/plans/archives/v0.57-request-flow.md` for implementation and operator authority.

---

## Verdict (decision-grade)

**Do not rewrite Allbert as the Pi port.** A rewrite trades a v0.54, 64-ADR, ~40-subsystem runtime with a *deliberately chosen authority model* for a single-user YOLO coding harness whose central premise Allbert has already, explicitly, rejected. The differentiated value of Allbert — Security Central, durable confirmations, the action boundary, channels/daemon, intent→objective routing, the codegen committee, artifacts, self-improvement — is exactly what Pi does not have and does not want.

**Do incorporate Pi's ideas — and recognize you already have, by convergent evolution.** The highest-value move is a scoped one: add a **Pi-mode coding surface as a channel/app on the existing spine**, and harvest three or four specific Pi ergonomics into the subsystems that already exist. Pi's real gift to Allbert is less code than a **minimalism budget** for the inner loop and tool surface — a forcing function against the accretion that 64 ADRs implies.

The tension you're feeling ("I like Pi's minimalism *and* Allbert's structure") is not an either/or. **Minimalism is a property of the inner loop and tool surface; structure is a property of the authority/runtime/channel spine.** You can — and your own Design Posture already wants to — run a minimal inner loop on a structured spine.

---

## 1. The one axis that settles the rewrite question: authority

Pi's defining sentence (Mario Zechner): *"pi runs in full YOLO mode and assumes you know what you're doing… No permission prompts… Full filesystem access."* Permissions are "mostly security theater" once the agent can run code, so Pi makes YOLO the only mode.

Allbert's defining sentence (`project-direction-rethink-01.md`): **"Advisory output is never authority."** LLM proposals "may propose, rank, predict, score, summarize, critique, explain… may not authorize execution, bypass `Actions.Runner.run/3`, Security Central, confirmations… short-circuit operator confirmation." And from the Jido vision: *"the assistant loop should not be 'LLM receives text and runs whatever it wants.'"*

These are not stylistic differences; they are **different threat models for different products**:

| | Pi | Allbert |
|---|---|---|
| Operator | A developer at *their own* terminal | A long-running assistant acting *across channels* (email, Discord, Matrix…) on the user's behalf |
| Trust surface | One human, one machine, owns everything | External inbound, scheduled jobs, generated code, third-party MCP |
| Right default | YOLO (guardrails are theater here) | Gated (a confirmation boundary is the entire point) |
| Failure cost | You broke your own repo | An autonomous agent emailed the wrong person / ran untrusted code |

Pi's "no permissions" is *correct for Pi* and *wrong for Allbert*. A rewrite would import Pi's threat model into a product that exists precisely because that threat model is insufficient. **This alone rules out the rewrite.**

---

## 2. Where Allbert already *is* Pi (convergent evolution)

"Incorporate Pi's ideas" is partly already done. Allbert independently arrived at most of Pi's good tenets:

- **Small explicit kernel, side effects behind validated actions, observable failure** — Allbert's Design Posture is almost a paraphrase of Pi's philosophy.
- **Externalized, file-based state instead of model-tracked state** — Pi: "no built-in to-dos; write a `TODO.md`." Allbert: markdown-first memory (ADR-0002), operator-edited source of truth. Same idea, deeper.
- **Progressive disclosure / lazy `SKILL.md`** — Pi's central anti-MCP argument *is* progressive disclosure. Allbert has had it since **v0.03**; the Hermes/OpenClaw comparison already notes both are converging on the pattern Allbert already uses.
- **Append-only session log** — Pi: JSONL with `parentSession`. Allbert/OpenClaw: append-only event logs + SQLite threads. Same shape.
- **Provider neutrality** — Pi: `pi-ai` across 15+ providers. Allbert: `req_llm` + provider doctor (ADR-0047) + capability prefs (ADR-0051).
- **Observability over black boxes** — Pi's whole pitch; Allbert's trace system + `jido_otel`.

So the question is narrower than it looks: **what does Pi still have that Allbert lacks?** Three things, below.

---

## 3. Comparison to adjacent systems: **Pi** (in the repo's borrow/don't-borrow format)

> Slotting Pi in next to the existing Hermes and OpenClaw entries.

**What Pi is.** A minimal *terminal coding harness* (not a personal-assistant runtime). Four tools — `read`, `write`, `edit`, `bash`. Sub-1000-token system prompt + `AGENTS.md`. Stateless loop until the model emits no tool calls. Tree/branch sessions. Mid-session model switch with cross-provider context handoff. Split tool results (one payload for the model, one for the UI). Scrollback-native TUI with differential rendering. No to-dos, no plan mode, no MCP, no sub-agents, no permissions.

**What Allbert can borrow from Pi:**

- **Split tool results (LLM payload vs. UI payload).** Pi's single cleanest idea. Maps directly onto typed runtime response contracts (ADR-0029) + the unified surface catalog/renderer (ADR-0030) and the canvas/ephemeral-surface substrate (ADR-0023). If an action's result doesn't already separate model-facing text from surface render payload, adopt it — pure upside, and it strengthens the canvas direction.
- **A minimal coding surface as a channel.** The vision already plans "a proper TUI/terminal channel under the ADR-0016 contract," and `mix allbert.ask` exists. Pi shows what the *good* version of that surface feels like: 4-tool simplicity, sub-1000-token prompt, full observability, streamed diffs. Build it on the action boundary + sandbox levels (ADR-0009), not on YOLO. Net: **Pi's ergonomics on Allbert's authority spine.**
- **Full-file-read / context-engineering discipline.** Pi's strongest empirical claim is that models under-read context and miss what they need, so you gather context deliberately in its own session and hand a clean artifact to a fresh one. This *supports* Allbert's Planner-gathers-context-first codegen structure and its artifact store — make it an explicit prompt/policy.
- **Mid-session model switch + context handoff.** `req_llm`'s canonical `Context` makes this structurally cheap; Pi shows it's worth surfacing as an operator affordance.
- **YOLO as a *named trust tier*, not a default.** Pi's YOLO is legitimate for exactly one case Allbert already has vocabulary for: a single trusted local operator, main session, **sandbox level 0**, terminal channel (cf. OpenClaw "main session runs native"). Offer a low-friction near-YOLO coding tier — gated by trust class, never the default, never for channel-originated or generated-code sessions.

**What Allbert should *not* borrow from Pi:**

- **YOLO-by-default / no action boundary.** Contradicts "Advisory output is never authority" and Security Central — the reason Allbert exists.
- **No-MCP-ever.** Allbert deliberately chose MCP-first integrations (ADR-0039), operator-consent-gated (ADR-0038) — a different concern than Pi's context-bloat critique. *Keep* Pi's actual point (lazy tool-description disclosure), which Allbert already does; *reject* the blanket ban.
- **LLM decides it's done.** Same reason Allbert rejected Hermes's completion model: acceptance must be deterministic evidence + confirmation, not model confidence.
- **Sub-agent-via-`bash`-spawn.** Allbert wants restricted-registry delegate agents (the Hermes "narrow the child's tools" lesson), not an opaque self-spawn.

---

## 4. Precisely where Pi fits: the 7-stage pipeline

The cleanest way to see "minimal loop on structured spine." Allbert's cognitive runtime is a seven-stage machine: **Receive → Interpret intent → Frame/resume objective → Propose/evaluate steps → Authorize step → Execute (`Actions.Runner.run/3`) → Observe/advance.**

Pi is essentially **{Receive → Interpret(implicit) → Execute(YOLO) → Observe}** — it has *no* stages 3, 4, or 5. That is the whole difference, stated structurally:

- Pi deletes objective framing, step proposal, and the authorization gate.
- Allbert's value is precisely stages 3–5.

So "incorporate Pi" has an exact meaning: **make stages 6–7 and the tool surface Pi-minimal** (four-tool simplicity, streamed split results, observable, sub-1000-token prompt) **while leaving stages 3–5 fully intact.** A Pi-mode coding session is one where the objective is "pair on this repo," step proposal is trivial, and authorization runs at sandbox level 0 for a trusted operator — the gates are *present but cheap*, not *absent*.

---

## 5. Where Pi sharpens the codegen committee (don't replace it)

Your `codegen-agent-loop-research.md` already (correctly) rejected Pi-style autonomy for generating *privileged* capabilities, in favor of a bounded Planner/Author/TrialAuthor/Critic/Repair committee over deterministic gates. Keep that. Pi contributes at the margins:

- Pi's **minimal-prompt** finding → trim the Author/Critic prompts; frontier models know what a coding agent is.
- Pi's **full-file context** finding → reinforces Planner-gathers-context-first; feed full files, not snippets, into the spec.
- Pi's **observability** ethos → the Critic and sandbox/gate reports as inspectable evidence (you already do this).

These are prompt/policy refinements, not architecture changes.

---

## 6. The meta-risk Pi actually exposes: accretion

64 ADRs and ~40 subsystems at v0.54 is the *opposite pole* from Pi's discipline. That's not a criticism — it's the cost of a real authority model and many channels — but it is the risk Pi is a useful mirror for. The most valuable thing Pi offers Allbert is a **minimalism budget**:

- A hard token budget for the inner conversational loop's system prompt (Pi: <1000 tokens).
- A hard cap on the *default* tool surface a conversational turn sees (Pi: 4; lazy-load the rest — you have the mechanism).
- A standing question for each new ADR: *does this belong in the kernel, or behind a contract/plugin/skill?* (Your own Boundary Actions rule, ADR-0007, already says the latter — Pi is the discipline to actually hold the line.)

Adopt the budget explicitly, as a coding policy in the rethink's "Coding Policies To Add" section.

---

## 7. Recommended sequencing (incremental, repo-style)

Small, evidence-gated inserts — consistent with "prove a contract, document authority, add evidence, then reuse":

1. **Harvest split tool results** into the typed response contract (ADR-0029) + renderer (ADR-0030). Cheapest, highest ergonomic ROI. Touches no authority.
2. **Define a "local coding" trust tier**: single trusted operator, main session, sandbox level 0, terminal channel. Names Pi's YOLO without making it default. (Extends ADR-0009 + trust-tier vocabulary.)
3. **Pi-mode coding surface** as a channel/app under ADR-0016: 4 boundary actions (`read`/`write`/`edit`/`bash`) routed through `Actions.Runner.run/3`, sub-1000-token prompt, streamed diffs via the split payload, full-file context policy. Reuse the existing skill loader and `AGENTS.md` hierarchy.
4. **Operator affordance for mid-session model switch** (req_llm context handoff). Small.
5. **Adopt the minimalism budget** as a coding policy + a recurring "does this belong in the kernel?" gate on new ADRs.

Reserved (not now): a TUI renderer choice (Pi's scrollback-native model ≈ ExRatatui inline viewport or Owl — but Allbert is LiveView-first, so the terminal channel can stay line-oriented until there's evidence it needs more).

---

## 8. What not to do (consolidated)

- Do not rewrite. Do not import YOLO-by-default. Do not weaken `Actions.Runner.run/3` / Security Central / confirmations for a coding surface — make the gates *cheap at level 0*, not *absent*.
- Do not adopt Pi's no-MCP stance; keep MCP-first with lazy disclosure.
- Do not let the coding surface's model "decide it's done" for anything effectful or generated-code-related; deterministic acceptance still rules.
- Do not build the Pi-mode surface as a *sibling runtime*. It is a channel/app on the one spine — same authority boundary, same trace, same memory.

---

## 9. Pi concept → Allbert home

| Pi concept | Already in Allbert | Action |
|---|---|---|
| Minimal loop (no tool calls → stop) | Stages 6–7 of the pipeline | Make Pi-mode's inner loop minimal; keep 3–5 |
| 4 tools | `actions/` boundary | Expose 4 boundary actions for coding; lazy-load rest |
| Split tool result (LLM vs UI) | ADR-0029 / ADR-0030 / ADR-0023 | **Adopt the split explicitly** |
| `SKILL.md` progressive disclosure | v0.03 | Already done — reuse |
| Externalized state (`TODO.md`/`PLAN.md`) | Markdown-first memory (ADR-0002) | Already done — deeper |
| Tree/branch sessions | Append-only logs + threads | Already aligned |
| Provider neutrality + model switch | req_llm + ADR-0047/0051 | Add mid-session switch affordance |
| YOLO | Sandbox levels (ADR-0009), trust tiers | Name a "local coding / level 0" tier |
| No MCP | MCP-first (ADR-0038/0039) | Keep MCP; keep lazy disclosure |
| Sub-agent via bash | Delegate agents (restricted registry) | Use delegate agents, not spawn |
| Minimal system prompt | — | **Adopt a prompt/tool budget policy** |
| Scrollback-native TUI | LiveView-first; terminal = channel | Reserved until evidence |

---

## 10. One-line answer

Keep Allbert's spine; give it Pi's inner loop where it makes sense (a gated coding surface), steal Pi's split-tool-result and minimalism budget everywhere, and treat Pi mainly as the discipline that keeps a 64-ADR system from forgetting its own Design Posture.
