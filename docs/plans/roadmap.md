# Allbert Roadmap (post-1.0)

The 0.x -> 1.0 roadmap is archived at [archives/1.0-roadmap.md](archives/1.0-roadmap.md)
(including the canonical 1.0 Acceptance Matrix). This roadmap covers the 1.x line.

## Release Model (1.x)

Every release is a **binary release**: tagged, CI-built, cosign-signed, published as a
GitHub Release, Homebrew tap filled. Each versioned plan covers one or more features and
ships as one or more point tags (1.0.1, 1.0.2, ...) that accumulate toward the next
minor (1.1, 1.2, ...). Minors carry one flagship feature each, foundational-first.
Plans follow the established triad convention (plan + request-flow, ADRs as needed);
the prioritization inventory is [future-features.md](future-features.md) — its Release
Ladder section is the operator-confirmed sequencing and is mirrored here.

## The Ladder

1. **1.0.1 — SHIPPED** (tagged `v1.0.1` 2026-07-15, source/docs point tag with
   `[skip-artifacts]` by operator decision — `v1.0.0` stays the packaged Latest;
   the fixes reach the artifact line with the next binary release): R15
   digest-manifest cache-busting, `btn` drift, offline service-worker guard,
   DIT-5 transcript, DIT-4 remediation M4.1–M4.5 (TUI launch, browser research
   end-to-end behind one consent gate, channel-send routing, packaged ACP
   handshake, cross-surface confirmation conformance), and the first standing
   dependency refresh (vendored `:memento` removed, ADR 0050 superseded).
   Plan: [archives/v1.0.1-plan.md](archives/v1.0.1-plan.md) +
   [archives/v1.0.1-request-flow.md](archives/v1.0.1-request-flow.md).
2. **1.0.x** — incremental: test suite speed & isolation (lane-by-lane, incl. the
   fast-local web split), v0.58 cleanup tails, Tier-2->Tier-1 promotion ADR (docs),
   intent-pipeline refinements (opportunistic), and the technical-debt train.
   (The vendored `:memento` removal landed early: 1.0.1's M5 refresh found
   `jido_signal` 2.2.2 dropped the pin — ADR 0050 superseded.)
3. **1.1 — Zero-Click First Run.** Chat-ready default with an auto-detected local
   model; onboarding optional and step-addressable; consent ADR; TUI first-run scope
   folded in. Enablers: model chooser/catalog, model fallback/degradation policy.
4. **1.2 — Long-Term User Memory.** Research phase first (STM/LTM/usage-history onto
   the Active Memory substrate), then periodic consolidation to reviewable drafts and
   prompt-time context for zero-shot answers. Horizon items: free-form provider URLs,
   non-local bind hardening.
5. **1.3 — Adaptive Usage Profiling.** System usage memory + distill/suggest jobs +
   one-click confirmed customizations + effectiveness feedback. Per-role model
   profiles and proactive notifications ride here.
6. **1.4 / 1.5 — enabler releases.** Migration-runner cluster (runner + telegram/email
   settings migration + legacy `intent.*model_profile` removal + automated rollback;
   pulled earlier if any prior release needs a non-additive migration), email OAuth
   (XOAUTH2), MCP 2025-11-25 spec parity, full param-contract enforcement,
   PermissionGate deletion, mid-action interruption + child-process cancellation,
   app-registry boundary check.
7. **Beyond** — System Memory Distillation is the post-1.3 co-flagship candidate;
   the Won't-now cluster stays in future-features.md with its review cadence.
8. **2.0 horizon — Self-Hosting Development.** Allbert develops Allbert (pi-mode
   target on its own checkout; plan/build/test/document roles in-product, supervised).
   Its OAuth hosted-LLM providers sub-capability (Claude/OpenAI/Gemini subscription
   plans, not just API keys) lands earlier on the 1.4/1.5 train.

## Working Rules

- The v1.0 public-contract freeze holds: `mix allbert.test release.v1` must stay green
  on every release; Tier-2 changes stay additive; Tier-1 changes need a major.
- Operator intake items enter future-features.md with class + effort + provenance,
  then slot into the ladder here.
- Upstream dependency refresh (confirmed 2026-07-15): every binary release plan
  carries a dependency-refresh milestone — review available updates across the tree
  (Jido stack, Phoenix/LiveView, Req, tooling), apply bounded updates, absorb the
  code changes, gates prove the result. A major/breaking upgrade may be scoped out
  to its own milestone or the next release with the reason recorded in the plan;
  an emergency hotfix release may skip the apply step (review still runs) with the
  skip recorded. (The rule's first standing checkpoint — the vendored `:memento`
  exit, ADR 0050 — resolved at the v1.0.1 M5 refresh.)
- Backlog lifecycle: an item that gains an implementation plan is marked
  `Status: planned — <plan doc>` in future-features.md and its ladder entry here
  links the plan triad. After the plan is implemented and tagged, the item is
  removed from future-features.md (only unplanned remainders stay) and this
  roadmap is updated accordingly (ladder entry marked shipped / re-sequenced).
