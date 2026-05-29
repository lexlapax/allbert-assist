# ADR 0043: Marketplace Lite Trust Tier

## Status

Proposed for v0.46 Marketplace Lite (`docs/plans/v0.46-plan.md`).

## Context

Allbert needs reviewed skill and template discovery before 1.0, but arbitrary
remote code-bearing plugin install requires a stronger signing, dependency,
sandbox, provenance, and rollback model than the 1.0 arc should take on.

## Decision

Marketplace lite permits:

- reviewed skill discovery and install into Allbert Home;
- reviewed-source plugin index metadata without automatic code install;
- template catalog metadata for `workspace:create`;
- provenance, hash, version, and rollback metadata.

Installed skills remain disabled and untrusted by default. Code-bearing remote
plugin install, binary plugin distribution, remote theme/snippet distribution,
and MCP Apps iframe execution are out of scope.

## Consequences

Operators can discover reviewed capabilities while Allbert keeps code authority
local, explicit, and reviewable before 1.0.

## Non-Goals

- No arbitrary remote code-bearing plugin install.
- No dependency resolution from marketplace metadata.
- No marketplace-provided permission grants.
