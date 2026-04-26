# ADR 0051: Daily cost cap is a hard gate enforced at turn boundary

Date: 2026-04-20
Status: Accepted

> **Planned v0.13 amendment**: a sibling daily compute cap (`learning.compute_cap_wall_seconds`) gates local LoRA training wall-clock time using the same UTC-day aggregate keying, 60s aggregate cache TTL, override pattern, fail-closed-for-jobs rule, and refusal-message shape as this ADR. Spend cap and compute cap are independent gates; both must pass at job dispatch and at every progress checkpoint. See ADR 0087.

## Context

Allbert tracks per-turn cost via CostHook (ADR 0006 + v0.1 work) and writes to `~/.allbert/costs.jsonl`. Through v0.5 there is no kernel-level daily spend cap: operators can inspect spend after the fact, but they cannot set a hard daily ceiling that refuses new turns.

This was tolerable when Allbert was a synchronous REPL and every turn required user intervention. With v0.2 scheduled jobs and v0.5 curated-memory maintenance loops in flight (and v0.7 sub-agent budget-governed depth coming), an unbounded cost loop is a real operational risk. A runaway job or a runaway sub-agent tree could burn significant provider spend before an operator notices.

## Decision

v0.6 introduces a new optional config key, `limits.daily_usd_cap`. At the start of every turn — REPL, channel-originated, or job-originated — the kernel reads today's aggregate from `costs.jsonl` keyed by UTC day. If the aggregate equals or exceeds `limits.daily_usd_cap` (when set to a non-null value), the turn refuses with a clear operator-facing message:

```
Daily cost cap of $X.XX reached for 2026-04-20. Current spend: $Y.YY.
Raise cap in config or run `/cost --override <reason>` to continue this turn.
```

### Rules

- **Override**: `/cost --override <reason>` is a REPL slash command; the override applies to exactly one turn and is logged in the trace with the reason. Channels without a slash-command surface receive the refusal message; override must be done from REPL (v0.7 may extend override to async channels via their own confirm pattern).
- **Jobs**: refuse silently, log the refusal in the job run record, and set the job's last-outcome to `cap-reached` so `allbert-cli jobs status <name>` surfaces it. A subsequent manual run after the UTC day rolls over proceeds normally.
- **Sub-agents**: inherit the parent's cap state. A sub-agent spawn that would push the aggregate over the cap refuses the same way a top-level turn does.
- **Aggregate caching**: cost aggregate is cached for 60 seconds to avoid per-turn file reads during job-dense bursts. Bounded exceedance is `60s × spend_rate`, which is acceptable for the scale of single-user personal use.
- **Null cap**: a `null` value (default until the wizard sets one) disables enforcement. The v0.6 wizard offers a sensible starting cap (suggested: $5/day) and explains how to raise or disable it.

### Placement

Enforcement lives in CostHook at `HookPoint::BeforeModel`, not in the provider adapter. This keeps the kernel as the policy surface (consistent with the security envelope's kernel-first principle) and means provider-specific cost paths inherit the same behaviour.

## Consequences

**Positive**

- Closes a foot-gun in a personal-assistant product that runs in the background with scheduled jobs.
- Operator-visible refusal keeps the failure mode honest; no silent drop.
- Enforcement is one code path, regardless of whether a turn originates from REPL, channel, or job.

**Negative**

- A too-low cap blocks legitimate work and requires operator override or config edit.
- The 60-second aggregate cache TTL allows brief over-cap bursts; acceptable at single-user scale.
- Override accounting relies on trace-log hygiene; operators auditing cost history must consult the trace to see override reasons.

**Neutral**

- Enforced in the kernel, not the provider. Provider-side limits (Anthropic, OpenRouter) remain a separate backstop and apply to aggregate account spend rather than per-day assistant behaviour.
- Daily boundary is UTC to match `costs.jsonl` keying. Local-timezone presentation is a future UX detail, not a correctness concern.

## References

- [ADR 0006](0006-hook-api-is-public-from-day-one.md)
- [ADR 0016](0016-scheduled-runs-use-fresh-sessions-and-may-attach-ordered-skills.md)
- [ADR 0025](0025-v0-2-daemon-shutdown-is-bounded-graceful-and-job-failures-are-surfaced.md)
- [docs/plans/v0.06-foundation-hardening.md](../plans/v0.06-foundation-hardening.md)
