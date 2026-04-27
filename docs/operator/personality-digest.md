# Personality digest operator guide

The personality digest is the current review-first markdown personalization seam. It drafts a learned collaboration overlay, but it never trains a model, never writes durable memory directly, and never mutates `SOUL.md`.

Start with the [v0.15.0 operator playbook](../onboarding-and-operations.md) for the full feature-test path.

## SOUL.md vs PERSONALITY.md

| File | Role | Creation | Authority |
| --- | --- | --- | --- |
| `SOUL.md` | Seeded constitutional persona: purpose, values, tone, boundaries, and behavioral stance. | Seeded on first boot; operator-owned. | Higher authority. Digest jobs must never write it. |
| `PERSONALITY.md` | Optional learned overlay: reviewed collaboration style and adaptation hints for this operator. | Installed from an accepted digest draft or edited directly by the operator. | Lower authority. It loses conflicts to current user instruction, `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, policy, and tool/security rules. |

Fresh profiles seed `SOUL.md` but not `PERSONALITY.md`. The bootstrap loader skips `PERSONALITY.md` when it is absent and loads it after `TOOLS.md` and before `AGENTS.md` when present.

## Config

The digest is disabled by default:

```toml
[learning]
enabled = false

[learning.personality_digest]
enabled = false
schedule = "@weekly on sunday at 18:00"
output_path = "PERSONALITY.md"
include_tiers = ["durable", "fact"]
include_episodes = true
episode_lookback_days = 30
max_episode_summaries = 10
max_input_bytes = 24576
max_output_bytes = 4096
```

`output_path` is relative to `ALLBERT_HOME`, must stay inside the profile, must be markdown, and cannot target reserved prompt/runtime paths such as `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, `AGENTS.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`, `config.toml`, `secrets/`, `run/`, `logs/`, `traces/`, `memory/`, `jobs/`, `skills/`, or `sessions/`.

## Commands

Preview the corpus without provider calls or file writes:

```bash
cargo run -p allbert-cli -- learning digest --preview
```

Run the digest once:

```bash
cargo run -p allbert-cli -- learning digest --run
```

Accept and install the generated overlay:

```bash
cargo run -p allbert-cli -- learning digest --run --accept
```

If the active model provider is hosted, v0.11 requires one-time profile-local consent before a run can proceed:

```bash
cargo run -p allbert-cli -- learning digest --run --consent-hosted-provider
```

Enable or disable the bundled job template without hand-editing job files:

```bash
cargo run -p allbert-cli -- jobs template enable personality-digest
cargo run -p allbert-cli -- jobs template disable personality-digest
```

## Draft And Install Flow

Digest runs write draft artifacts first:

```text
~/.allbert/learning/personality-digest/runs/<run_id>/corpus.json
~/.allbert/learning/personality-digest/runs/<run_id>/draft.md
~/.allbert/learning/personality-digest/runs/<run_id>/report.json
```

Accepted output installs atomically to the configured output path, `~/.allbert/PERSONALITY.md` by default.

Digest-generated overlays include provenance frontmatter:

```yaml
version: 1
kind: personality_digest
authority: learned_overlay
generated_by: allbert/personality-digest
source_run_id: run-...
corpus_digest: sha256:...
corpus_tiers:
  - durable
accepted_at: "2026-04-24T00:00:00Z"
```

The body uses fixed sections:

- `Learned Collaboration Style`
- `Stable Interaction Preferences`
- `Useful Cautions`
- `Open Questions`

`PERSONALITY.md` must not store raw transcript excerpts, unapproved staged facts, or durable factual claims that belong in memory. Net-new learnings still route through staging.

## Digest And Adapters

The digest remains the human-readable markdown overlay. Local adapter training is a second, optional personalization surface that plugs into the same `LearningJob` seam and review-first envelope. Adapter training can consume accepted `PERSONALITY.md` as input, but it does not replace it and does not write `SOUL.md`.

Use the digest when you want inspectable collaboration guidance in markdown. Use personalization adapters when you have opted into local training and want a base-model-pinned local adapter reviewed through `adapter-approval`.

## Related Docs

- [v0.15.0 operator playbook](../onboarding-and-operations.md)
- [Adaptive memory guide](adaptive-memory.md)
- [Personalization guide](personalization.md)
- [v0.11 upgrade notes](../notes/v0.11-upgrade-2026-04-24.md)
- [v0.13 upgrade notes](../notes/v0.13-upgrade-2026-04-26.md)
