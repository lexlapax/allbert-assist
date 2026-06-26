# ADR 0075: User-Category Settings Profiles (Personas)

Status: Proposed (v0.62).
Date: 2026-06-25
Related: ADR 0004 / ADR 0031 (Settings Central — profiles seed defaults through
it and nowhere else), ADR 0069 (guided onboarding — the primary place a profile
is applied), ADR 0072 (model recommendations — profiles reference recommended
model purposes), ADR 0006 (Security Central — profiles grant no authority).
Anchors the v0.62 "profiles" half of Guided Onboarding & Profiles.

## Context

A new operator today lands on a blank, undifferentiated configuration: one
"default profile" exists purely for hygiene, and there is no concept of "what
kind of user am I." Every operator must discover, one setting at a time, which
apps, channels, intents, and model defaults make sense for their work.

The 2026 competitive bar is **opinionated presets over raw config** — Claude
Desktop's effort toggle, OpenClaw's QuickStart defaults, Msty's personas. Hiding
a settings matrix behind one human-readable choice is now expected, especially
for the technical-prosumer audience who wants polish without a config tour.

Allbert has the substrate (Settings Central, the app/channel/intent catalogs, the
ADR 0072 recommendation matrix) but no preset layer that turns "I am a
researcher / developer / writer / ops person" into a tailored starting point.

## Decision

Introduce **repo-maintained user-category profiles** (personas): declarative,
version-controlled presets that seed a tailored starting configuration.

- **Shipped categories** (extensible): `researcher`, `developer`, `writer`,
  `ops`, `general`.
- **Each profile is a reviewed, in-repo declarative preset** that specifies:
  Settings Central default values; a suggested set of apps to enable; suggested
  channels; suggested intents; and a recommended model-purpose mapping (referencing
  ADR 0072 recommendations, not pinning specific endpoints).
- **Application is explicit and reviewable.** A profile is applied during guided
  onboarding (ADR 0069) or through a registered settings action, always with an
  operator review/confirm step that shows exactly what will be seeded.
- **Repo-maintained, not user-generated.** Profiles are curated and reviewed in
  the source tree — the same trust posture as reviewed plugins, and a deliberate
  contrast with open community preset marketplaces.

## Consequences

- A new user gets a tailored, sensible starting point with one choice instead of
  a settings tour — the onboarding "opinionated preset" the competitive bar
  expects.
- **Seed-only semantics: profiles are defaults, not authority.** Applying a
  profile only pre-populates operator-tunable Settings Central values and
  suggestions the operator can change. It lowers no confirmation floor, grants no
  egress, enables nothing effectful without the normal gates, and Security Central
  (ADR 0006) is unchanged.
- Profiles flow through Settings Central (ADR 0004/0031) like any other settings
  write — they are not a configuration side channel.
- The curated/reviewed model is a trust differentiator and keeps the preset set
  small and legible for the v1.0 freeze.

## Non-goals and guardrails

- **Not runtime authorization.** A profile is not a permission set, a trust tier,
  or a per-user authority model; it cannot grant capabilities.
- **Not learned or auto-generated.** Personas are reviewed in-repo presets, not
  distilled from traces or model output (that stays a durable non-goal); the
  existing free-text `persona.md`/identity memory is unrelated operator content.
- **Not hosted/multi-user.** Profiles are local operator presets, not a
  multi-tenant role system.
- Profiles never override Security Central, confirmations, or the action boundary.
