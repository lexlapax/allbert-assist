# Cost-cap posture

Allbert's `limits.daily_usd_cap` is currently **per device profile**, not a globally shared cap.

This behavior remains the explicit shipped policy in v0.14.3. Start with the [v0.14.3 operator playbook](../onboarding-and-operations.md) for the full feature-test path.

## What this means in practice

- If you run Allbert on one machine, the configured daily cap behaves as expected for that device.
- If you run Allbert on multiple machines, each profile enforces its own cap independently.
- Effective aggregate spend across `N` active devices can be approximately `N × daily_usd_cap`.

## Why this is the current behavior

This follows the local-only continuity posture in ADR 0061. Today there is no hosted/shared counter for cost usage, and Allbert intentionally avoids introducing one in the current local-only source release.

## Explicit non-goal in v0.14.3

Cross-device aggregate cap enforcement is out of scope for v0.14.3. Local adapter training has a separate wall-clock cap, `learning.compute_cap_wall_seconds`; self-diagnosis, local utilities, and router reliability changes do not change hosted-provider spend-cap aggregation.

A future design would require either:

- a central shared counter/service, or
- a sync-safe replicated counter approach (for example CRDT-backed accounting),

which depends on hosted/sync capabilities that are not part of v0.14.3.
