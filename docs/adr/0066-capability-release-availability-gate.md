# ADR 0066: Capability Release Availability Gate

Status: Proposed (v0.53 M11; accepted only after code, tests, docs, and release
gate evidence land).
Date: 2026-06-20
Related: ADR 0016 (channel boundary), ADR 0017 (plugin contract), ADR 0056
(channel inbound trust tier), ADR 0057 (cross-channel threading), ADR 0058
(key custody and daemon supervision), ADR 0059 (channel trust class), ADR 0006
(Security Central). ADR 0065 remains reserved for the v0.58 central action
param-contract enforcement work and must not be reused by this decision.

## Context

v0.53 implemented the WhatsApp Cloud API adapter and the Signal `signal-cli`
bridge, but manual release validation showed that live provider onboarding is
too heavy to keep as a v0.53 tag blocker:

- WhatsApp Cloud API validation was blocked by Meta object/permission and
  account-registration failures in the developer UI and Graph API, even though
  the adapter, signed-webhook ingress, and deterministic eval paths exist.
- Signal live validation requires an operator-managed `signal-cli` daemon,
  linked-device or registration flow, ACI discovery, and local control endpoint
  setup. That is useful advanced-bridge work, but not an acceptable
  frictionless release prerequisite.

Allbert therefore needs a system-wide way to distinguish **implemented** from
**released for live use**. That mechanism must not be a new authority boundary:
Security Central, permissions, confirmations, credentials, resource access,
adapter allowlists, and provider auth remain the enforcement layers.

The gate also must not fail closed for unknown capabilities. Allbert already has
many core and plugin actions without release metadata. Treating undeclared
capabilities as blocked would brick existing released surfaces. v0.53 M11 is a
release-availability overlay, not a complete capability inventory freeze.

## Decision

Add a capability release-availability gate with refs for at least:

- `channel`
- `action`
- `plugin`
- `app`

The v0.53 M11 implementation only needs declarations for WhatsApp and Signal;
later milestones may broaden the metadata surface.

### Default semantics

- Missing declaration, missing YAML, missing plugin release file, or otherwise
  unknown ref means **released by default**.
- A valid explicit declaration with `live_use_allowed: false` fails closed for
  that declared capability.
- The gate must report a clear operator-facing status such as
  `implemented_not_released` instead of attempting live provider side effects.

This default is intentional compatibility, not a security shortcut. Security
decisions still happen at the existing action/channel/permission boundaries.

### Declaration source

Plugin-owned release declarations are preferred. For v0.53 M11, ship
declarations only where the release decision is non-default:

- WhatsApp channel: implemented, not released for live use.
- Signal channel: implemented, not released for live use.
- Signal live-link/send actions that would initiate the advanced bridge may also
  be declared if they need direct action-runner blocking.

An optional operator/developer YAML overlay can be added later, but v0.53 must
not require a complete 12-plugin metadata sweep before closeout.

### Enforcement planes

- Channel-facing setup/show/send paths must surface explicit unreleased status
  for WhatsApp and Signal and must not perform live sends when the declared
  channel is blocked.
- Action-runner enforcement applies only to explicitly declared blocked action,
  plugin, or app refs. Undeclared core actions continue to run through their
  existing security and permission gates.
- Diagnostics may remain runnable when useful, provided they do not perform the
  blocked live side effect and clearly label the release status.

## Consequences

- v0.53 can close without pretending WhatsApp/Signal live validation passed.
- Operators get truthful CLI/docs behavior: Telegram, email, and Matrix are
  validated; WhatsApp and Signal are implemented but not released.
- Future WhatsApp Cloud API, WhatsApp Web/Baileys, or Signal onboarding work can
  resume from an explicit release state rather than an ambiguous validation
  failure.
- No existing core action surface is blocked merely because it lacks release
  metadata.

## Known Limitations

- v0.53 M11 does not require exhaustive release metadata for every shipped
  plugin or core action.
- Core actions without a plugin home are not declarable through plugin-owned
  YAML in this milestone.
- The gate is retrofitted late in v0.53 after the adapters were already built;
  v0.55+ work should prefer declaring release availability alongside new
  capability registration.
