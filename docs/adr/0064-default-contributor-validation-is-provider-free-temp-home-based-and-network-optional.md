# ADR 0064: Default contributor validation is provider-free, temp-home based, and network-optional

Date: 2026-04-21
Status: Proposed

## Context

Allbert already has good fake-provider coverage in the kernel and daemon tests, but the repo does not yet state clearly which checks are required for a normal contributor green path and which are optional live verifications.

That ambiguity creates two problems:

1. contributors can wrongly assume they need Anthropic/OpenRouter keys for routine development;
2. coding agents in ephemeral environments can waste time or fail unnecessarily when secrets or network access are unavailable.

The repo also relies on `ALLBERT_HOME` for safe profile isolation, but that is not yet the explicit default contributor posture.

## Decision

v0.9 defines two contributor validation tiers.

### Tier A — required contributor green

The default required validation path is:

1. `cargo fmt --check`
2. `env -u RUSTC_WRAPPER cargo clippy --workspace --all-targets -- -D warnings`
3. `env -u RUSTC_WRAPPER cargo test -q`
4. `env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- --help`

Tier A must be:

- provider-free
- network-optional
- safe against the contributor's real profile

Contributor smoke flows use a temporary `ALLBERT_HOME`.

### Tier B — optional live verification

Live-provider and real-integration checks remain optional:

- Anthropic/OpenRouter verification
- Telegram testing
- any checks that need real secrets or network

Tier B is never required for routine contributor green status in v0.9.

### Environment rule

`RUSTC_WRAPPER` may exist locally, but must not be assumed. Contributor docs use `env -u RUSTC_WRAPPER ...` for canonical validation commands so workspaces without `sccache` still work cleanly.

## Consequences

**Positive**

- Contributors know exactly what “green” means without live secrets.
- Codex Web and other ephemeral workspaces can validate normal changes reliably.
- Temp-home discipline becomes standard instead of tribal knowledge.

**Negative**

- Some real provider/channel regressions remain outside the default contributor gate and must still be checked intentionally.

**Neutral**

- This ADR does not remove optional live checks; it just keeps them out of the default contributor contract.

## References

- [docs/plans/v0.9-developer-environment-and-codex-web.md](../plans/v0.9-developer-environment-and-codex-web.md)
