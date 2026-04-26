# ADR 0087: Adapter compute cap is a wall-clock daily gate

Date: 2026-04-25
Status: Accepted

Amends: [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)

## Context

ADR 0051 enforces a daily monetary spend cap at turn boundary. It governs *USD spent on hosted-provider tokens*. Local LoRA training has near-zero monetary cost (no provider call, no token spend) but a non-trivial wall-clock and energy cost. A runaway training loop or a misconfigured `learning.adapter_training` block could keep the user's machine pinned for hours without crossing the spend cap.

The release needs an explicit second cap covering local compute time. The cap should follow the ADR 0051 shape so operators do not have to learn a new gate.

## Decision

v0.13 introduces `learning.compute_cap_wall_seconds` as a kernel-enforced daily ceiling on local-training wall-clock time, modelled on `limits.daily_usd_cap` from ADR 0051.

```toml
[learning]
compute_cap_wall_seconds = 7200       # default: 2 hours
compute_cap_override_per_run = true   # operator may override per training run with a reason
```

### Rules

- **Aggregate basis.** The kernel reads today's aggregate compute time from `~/.allbert/adapters/runs/*/manifest.json` keyed by UTC day, the same key ADR 0051 uses. Aggregate is cached for 60 seconds.
- **Enforcement point.** A `PersonalityAdapterJob` invocation evaluates the cap at job dispatch and at every progress checkpoint. If today's aggregate plus the run's elapsed time would exceed the cap, the job refuses to start with an actionable message; if a checkpoint shows the cap has been crossed mid-run, the kernel sends `cancel` to the trainer subprocess and finalizes the run with `status = cap-exceeded`.
- **Refusal message.** Mirrors ADR 0051's shape:

```
Daily compute cap of 7200s reached for 2026-05-01. Today's training time: 6921s.
Raise cap with `/settings set learning.compute_cap_wall_seconds <n>` or run `adapters training start --override <reason>` to continue this run.
```

- **Override.** `adapters training start --override <reason>` consumes a one-run override. The override is recorded in the training-run manifest under `compute_cap_override.{reason, requested_at, requested_by}`. Channels without a CLI surface refuse and direct the operator to REPL/CLI; this matches ADR 0051's REPL-only override.
- **Jobs.** Scheduled `PersonalityAdapterJob` runs that hit the cap refuse silently, log the refusal in the job run record, and set the job's last-outcome to `compute-cap-reached`. ADR 0015 (fail-closed scheduling) applies: scheduled training never auto-overrides the cap.
- **Sub-trainers.** The cap is per top-level training run; chained or restart-resumed runs share the same UTC-day aggregate.
- **Null cap.** A `null` value (or `0`) disables enforcement. The default is `7200` (2 hours) and the v0.13 setup wizard explains how to raise or disable it.
- **Double-counted with the spend cap?** No. They count distinct resources. A hosted training run (deferred beyond v0.13) would consume both caps independently.

### Placement

Enforcement lives in the job dispatch path and in the trainer-progress hook, not in the trainer subprocess itself. This keeps the kernel as the policy surface, consistent with the ADR 0051 reasoning, and means future trainer backends inherit the same gate.

### Reporting

`LearningJobReport.resource_cost` for adapter training records `compute_wall_seconds` as a `u64` and `peak_resident_mb` as a `u64`. The training-run manifest carries the same fields plus `started_at`, `ended_at`, `cancelled_at` (when applicable), and `cap_remaining_at_start_seconds`. `allbert-cli adapters status` surfaces today's aggregate and remaining cap.

## Consequences

**Positive**

- Local training cannot quietly pin the operator's machine.
- Operators get one consistent gating story (ADR 0051 for spend, this ADR for compute) and the same override pattern.
- Cap reporting is visible in the same telemetry surfaces the spend cap already populates.

**Negative**

- Operators training on slow hardware may need to raise the default cap. Acceptable: the message names the exact key to change.
- The 60-second aggregate cache TTL allows brief over-cap bursts. Acceptable at single-user scale, mirroring ADR 0051.

**Neutral**

- Resident-memory-time accounting (GPU MB × s) is intentionally not the v0.13 unit. A future ADR can add it as a richer metric without changing the seam.
- This cap covers training. Inference runs against an active adapter inherit the existing turn-budget gates and the spend cap; they do not consume the compute cap.

## References

- [docs/plans/v0.13-personalization.md](../plans/v0.13-personalization.md)
- [ADR 0015](0015-scheduled-jobs-fail-closed-on-interactive-actions.md)
- [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md) — amended by this ADR (adds compute cap as a sibling gate).
- [ADR 0084](0084-personality-adapter-job-is-a-learning-job-with-an-owned-trainer-trait.md)
- [ADR 0086](0086-adapter-approval-is-a-new-inbox-kind.md)
