# ADR 0039: MCP-First, Native-Plugin-Second Integrations

## Status

Proposed for v0.41 Everyday Integration Pack 1
(`docs/plans/v0.41-plan.md`).

## Context

Allbert needs everyday integrations without growing provider-specific core
dependencies. v0.40 MCP can cover many tool calls, while native plugin/app
surfaces are still valuable when Allbert needs richer workspace UI, memory
namespace ownership, or intent descriptors.

## Decision

For first-wave integrations:

- Prefer MCP server configuration for generic tool/resource operations.
- Add native plugin/apps only when the integration needs workspace panels,
  app-owned memory namespace, intent descriptors, or local supervision.
- Allbert core does not take dependencies on Google, GitHub, mail-provider,
  notes, or calendar APIs.
- Native plugin actions still run through the normal action/security boundary.

## Consequences

The integration surface expands quickly while core remains small. Operators can
start with MCP and graduate an integration to a plugin/app only when Allbert's
workspace model needs a richer local participant.

## Non-Goals

- No provider-specific integration clients in core.
- No bypass of Resource Access or confirmations.
- No automatic memory promotion from integration output.
