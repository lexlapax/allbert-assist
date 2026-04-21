# ADR 0065: Repo contributor instructions are distinct from runtime bootstrap artifacts

Date: 2026-04-21
Status: Accepted

## Context

Allbert already uses runtime bootstrap markdown files under `~/.allbert/`, including a kernel-generated `~/.allbert/AGENTS.md`. That runtime file is part of the assistant's prompt/context model.

The source repository now also needs contributor-facing instructions for humans and coding agents working on the codebase itself. Without an explicit distinction, a repo-level `AGENTS.md` could be confused with the runtime-generated `~/.allbert/AGENTS.md`, leading to documentation drift or incorrect assumptions about what the product injects into prompts.

## Decision

v0.9 introduces repo-level contributor artifacts that are explicitly separate from runtime bootstrap artifacts:

- root `AGENTS.md` — contributor and coding-agent workflow guidance for this repository
- `DEVELOPMENT.md` — contributor setup and validation guide
- `.env.example` — optional live-check env vars only

The repo-level `AGENTS.md` is never part of Allbert's runtime bootstrap bundle. It is source-tree documentation only.

The runtime-generated `~/.allbert/AGENTS.md` remains kernel-owned and product-facing.

Contributor docs must call out this distinction explicitly anywhere the name could be ambiguous.

## Consequences

**Positive**

- Contributors and coding agents get repo-local instructions without polluting runtime semantics.
- The distinction between source-tree docs and runtime bootstrap artifacts stays legible.
- Future coding-agent workflows have a clear home for repository-specific guidance.

**Negative**

- The project now has two different `AGENTS.md` concepts, so docs must stay careful and explicit.

**Neutral**

- This ADR does not change the runtime-generated file or its bootstrap role.

## References

- [ADR 0039](0039-agents-md-joins-the-bootstrap-bundle-in-v0-3.md)
- [docs/plans/v0.9-developer-environment-and-codex-web.md](../plans/v0.9-developer-environment-and-codex-web.md)
