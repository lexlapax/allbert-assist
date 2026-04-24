# ADR 0063: Development environment is rustup-pinned and supported on macOS and Linux

Date: 2026-04-21
Status: Accepted

## Context

Through v0.8, Allbert is well specified as a source-based product for technical end users, but the repository itself does not yet declare a reproducible contributor environment. That makes local contributor setup and remote coding-agent setup depend on unstated workstation assumptions.

The main missing pieces are:

- no in-repo Rust toolchain pin;
- no declared contributor platform support matrix;
- no statement of the required toolchain manager;
- no single source of truth for required Rust components.

That gap becomes risky before v0.12 self-improvement. A rebuild skill or coding agent needs a declared development contract rather than whatever happens to be installed on the current machine.

## Decision

v0.9 adds a pinned Rust contributor environment for this repository.

- Supported contributor platforms:
  - macOS
  - Linux
- Unsupported through v0.9:
  - Windows native
- Required toolchain manager:
  - `rustup`
- Required pinned toolchain:
  - Rust `1.94.0`
- Required components:
  - `rustfmt`
  - `clippy`

The repo will ship `rust-toolchain.toml` at root so local shells, Codex Web workspaces, and other ephemeral environments converge on the same compiler and component set.

This ADR is about the **development environment**, not the end-user runtime posture. Allbert remains a local-first daemon product; this ADR only standardizes how the source tree is built and validated by contributors.

## Consequences

**Positive**

- Local macOS/Linux contributors and Codex Web workspaces get the same default toolchain.
- Clippy/fmt/test behavior becomes more reproducible.
- v0.10 provider expansion can assume a provider-free validation contract while the hosted/local provider matrix grows.
- v0.12 self-improvement can assume a declared Rust toolchain contract.

**Negative**

- Toolchain upgrades become an explicit maintenance decision instead of drifting with whatever is newest locally.
- Windows-native contributors remain out of scope until a later release explicitly adds support.

**Neutral**

- This does not add CI by itself.
- This does not change the product runtime support story for end users.

## References

- [docs/plans/v0.09-developer-environment-and-codex-web.md](../plans/v0.09-developer-environment-and-codex-web.md)
- [docs/plans/v0.10-provider-expansion.md](../plans/v0.10-provider-expansion.md)
- [docs/plans/v0.12-self-improvement.md](../plans/v0.12-self-improvement.md)
