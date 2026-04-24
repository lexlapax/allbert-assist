# ADR 0055: Channel trait with capability flags

Date: 2026-04-20
Status: Accepted

## Context

[ADR 0013](0013-clients-attach-to-a-daemon-hosted-kernel-via-channels.md) established channels as the abstraction by which clients attach to the daemon-hosted kernel. In practice, through v0.6 only the REPL/CLI channel has existed, and `ChannelKind` in `allbert-proto` is a three-variant enum (`Cli`, `Repl`, `Jobs`) with implicit per-variant handling spread across the daemon and kernel.

v0.7 adds a Telegram pilot and expects more channels to follow (Discord, email, SMS, web, future native surfaces). Without a shared trait, each channel either:

- hard-codes REPL-ish assumptions (synchronous turn, inline confirm, terminal rendering) that do not hold for async channels, or
- bolts channel-specific logic into the daemon, duplicating trust, rate-limiting, confirm, and rendering concerns per adapter.

The capability-flag vocabulary surfaced in the v0.7 plan (`supports_inline_confirm`, `supports_async_confirm`, `supports_image_input`, etc.) is the right shape. What is missing is a formal trait that makes the capabilities load-bearing at runtime.

## Decision

Introduce a `Channel` trait. Crate placement: a new `allbert-channels` crate in the workspace. Rationale: Telegram and later adapters pull in non-trivial dependency graphs (teloxide, reqwest, serde_json) that should not be mandatory in the core daemon crate or in tests that do not exercise channels.

### Trait surface

```rust
#[async_trait]
pub trait Channel: Send + Sync {
    fn kind(&self) -> ChannelKind;
    fn capabilities(&self) -> ChannelCapabilities;

    async fn receive(&self) -> Result<ChannelInbound>;
    async fn send(&self, out: ChannelOutbound) -> Result<()>;

    async fn confirm(&self, prompt: ConfirmPrompt) -> Result<ConfirmOutcome>;

    async fn shutdown(self: Arc<Self>) -> Result<()>;
}

pub struct ChannelCapabilities {
    pub supports_inline_confirm: bool,
    pub supports_async_confirm: bool,
    pub supports_rich_output: bool,
    pub supports_file_attach: bool,
    pub supports_image_input: bool,
    pub supports_image_output: bool,
    pub supports_voice_input: bool,
    pub supports_voice_output: bool,
    pub supports_audio_attach: bool,
    pub max_message_size: usize,
    pub latency_class: LatencyClass,
}

pub enum LatencyClass { Synchronous, Asynchronous, Batch }
```

`ChannelInbound`/`ChannelOutbound` carry the channel-local sender identifier, text payload, and optional media attachments. `ConfirmPrompt`/`ConfirmOutcome` reuse the v0.2 confirm-trust types (ADR 0007) but become trait-dispatched rather than closure-captured.

### Kernel consultation points

The daemon consults `capabilities()` at turn time:

- **Confirm-trust** (ADR 0007) picks path by capability: `supports_inline_confirm` → blocking prompt; `supports_async_confirm` and not inline → suspend-resume state machine (ADR 0056). Neither → policy-gated actions fail closed.
- **Scheduled jobs** (ADR 0015) already fail closed on interactive actions. The capability model formalises why: jobs have no channel, so no capability flag is `true`.
- **Turn-end staged-memory notice** (ADR 0050) consults `latency_class`: synchronous channels render inline, asynchronous channels append to the next outbound message, batch channels may omit.
- **Multimodal** skills query capability flags before assuming an input modality is available.

### Trust model

- Each channel owns a per-channel allowlist file adjacent to `~/.allbert/config` (e.g. `channels.telegram.allowed_chats`). Unknown senders are ignored with an audit entry; no channel message creates a session without an explicit allowlist entry.
- Channel tokens/credentials live under `~/.allbert/secrets/<channel>/` with the same filesystem-mode as the IPC socket (ADR 0023).
- The allowlist is operator-managed as markdown or simple config; not the kernel's job to mint identities.

### Lifecycle

- `daemon start` enumerates configured channels and spawns one driver task per channel.
- `daemon channels list | status [<kind>] | add <kind> | remove <kind>` CLI commands expose channel state.
- In v0.7 the admin surface is generic, but bounded to built-in known kinds. `telegram` is the only non-REPL addable kind in this release.
- `add <kind>` creates or updates the channel config entry, scaffolds required allowlist and secret file paths if missing, marks the channel enabled, and leaves the channel in `misconfigured` / `needs_setup` until the operator supplies valid secrets and allowlist content.
- `remove <kind>` disables the channel in config and stops loading it on next daemon start or reload. It does not delete secret or allowlist files.
- `status` must surface at least enabled/disabled, configured/misconfigured, last error, queue depth if running, and effective capability flags.
- `shutdown` is bounded graceful per ADR 0025; channels surface outstanding message queues and drain on best-effort.

## Consequences

**Positive**

- Adding a new channel is implementing one trait plus the per-channel allowlist.
- Every channel inherits uniform confirm, trust, rendering, and rate-limiting hooks.
- Capability negotiation replaces implicit synchronous-REPL assumptions.
- `ChannelCapabilities` becomes the contract that skills and the kernel consult, so a skill that requires images (say) fails fast on a text-only channel rather than failing opaquely.

**Negative**

- The trait must stay stable early or per-channel migration pain compounds. v0.7 takes the first cut; v0.8 will likely extend the struct for continuity-aware surfaces (identity mapping, cross-channel session routing).
- A new crate is a workspace change. Cross-crate imports must stay acyclic: `allbert-channels` depends on `allbert-proto` and (for the daemon-side driver) pieces of `allbert-daemon`, not the reverse.
- `Tool` trait-objects in `ToolCtx` and `Channel` trait-objects in the daemon session map both live in `Arc<dyn ...>` form; test ergonomics in downstream crates lose some concreteness.

**Neutral**

- Supersedes the informal channel contract assumed by `ChannelKind` in `allbert-proto`. `ChannelKind` remains as the coarse taxonomy (`Cli`, `Repl`, `Jobs`, `Telegram`, …) so the protocol layer stays stable.
- ADR 0013 remains accurate at the conceptual level; this is its concrete v0.7 realisation.
- Non-REPL channels introduced later may share the Telegram session model (ADR 0057) or pick their own — the trait makes that an adapter-level choice surfaced through capability flags and session-attach behaviour.

## References

- [ADR 0007](0007-session-scoped-exact-match-confirm-trust.md)
- [ADR 0013](0013-clients-attach-to-a-daemon-hosted-kernel-via-channels.md)
- [ADR 0015](0015-scheduled-jobs-fail-closed-on-interactive-actions.md)
- [ADR 0018](0018-kernel-must-be-capable-of-running-as-a-long-lived-daemon-host.md)
- [ADR 0023](0023-local-ipc-trust-is-filesystem-scoped-no-token-auth-in-v0-2.md)
- [ADR 0025](0025-v0-2-daemon-shutdown-is-bounded-graceful-and-job-failures-are-surfaced.md)
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0050](0050-turn-end-staged-memory-notice-is-kernel-rendered-togglable-suffix.md)
- [ADR 0056](0056-async-confirm-is-a-suspend-resume-turn-state.md)
- [ADR 0057](0057-telegram-pilot-uses-teloxide-and-long-polling.md)
- [docs/plans/v0.07-channel-expansion.md](../plans/v0.07-channel-expansion.md)
