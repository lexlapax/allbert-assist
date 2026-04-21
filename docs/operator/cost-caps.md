# Cost-cap posture (v0.8 preparation for M9)

Allbert's `limits.daily_usd_cap` is currently **per device profile**, not a globally shared cap.

## What this means in practice

- If you run Allbert on one machine, the configured daily cap behaves as expected for that device.
- If you run Allbert on multiple machines, each profile enforces its own cap independently.
- Effective aggregate spend across `N` active devices can be approximately `N × daily_usd_cap`.

## Why this is the current behavior

This follows the local-only continuity posture in ADR 0061. Today there is no hosted/shared counter for cost usage, and v0.8 intentionally avoids introducing one.

## Explicit non-goal through v0.10

Cross-device aggregate cap enforcement is out of scope through v0.10.

A future design would require either:

- a central shared counter/service, or
- a sync-safe replicated counter approach (for example CRDT-backed accounting),

which depends on hosted/sync capabilities that are not planned before v0.11.
