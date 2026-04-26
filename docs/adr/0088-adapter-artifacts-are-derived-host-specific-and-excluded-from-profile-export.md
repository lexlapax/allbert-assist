# ADR 0088: Adapter artifacts are derived/host-specific and excluded from profile export

Date: 2026-04-25
Status: Accepted

Amends: [ADR 0061](0061-local-only-continuity-posture.md)

## Context

ADR 0061 sets the local-only continuity posture and names which `~/.allbert/` paths travel through profile export and which do not. v0.12.2 added session trace artifacts as continuity-bearing (ADR 0081) because traces are needed for cross-device replay and v0.14 self-diagnosis.

v0.13 introduces a new artifact root: `~/.allbert/adapters/`. It contains training run staging, installed adapter weights, the active-adapter pointer, history, and incoming external adapters. The release must decide whether these travel with the operator profile.

The right call is the opposite of v0.12.2's: adapters should NOT travel by default. Three reasons:

1. **Size.** A single LoRA adapter is tens of megabytes to gigabytes. A history of accepted adapters multiplies that. Profile export was sized for markdown, configuration, and bounded session artifacts; multi-GB binary weights would change its character.
2. **Host specificity.** Adapter weights are paired with a specific base-model digest. A peer machine that runs a different Ollama model build, a different llama.cpp binary, or different hardware may not be able to load the same adapter. Re-training against the peer's base produces a working adapter; copying the weights does not always.
3. **Reproducibility.** The corpus inputs (durable memory, accepted facts, bounded episode summaries, accepted `PERSONALITY.md`, `SOUL.md`) DO travel through profile export. A peer machine has everything needed to re-train its own adapter against the same corpus. The trained weights are derived from that corpus the same way the Tantivy index is derived from durable memory markdown.

## Decision

v0.13 adapter artifacts under `~/.allbert/adapters/` are derived/host-specific and are excluded from profile export and filesystem sync by default. The exclusion covers:

```text
~/.allbert/adapters/runs/                # training run staging
~/.allbert/adapters/installed/           # accepted adapter weights
~/.allbert/adapters/incoming/            # operator-dropped external adapters awaiting review
~/.allbert/adapters/runtime/             # provider-side derived Modelfiles and caches
~/.allbert/adapters/active.json          # active-adapter pointer
~/.allbert/adapters/history.jsonl        # activation/deactivation/removal history
```

The training corpus inputs continue to travel as before because they live outside `~/.allbert/adapters/`:

- approved durable memory under `~/.allbert/memory/notes/` (per ADR 0061);
- approved facts under the v0.11 fact tier;
- accepted `PERSONALITY.md` at the configured digest output path;
- `SOUL.md` and other bootstrap markdown (ADR 0010);
- v0.12.2 redacted session traces under `sessions/<sid>/trace*` (per ADR 0081), if the operator opts into trace-augmented training.

The `adapter-approval` markdown under `sessions/<sid>/approvals/` follows the existing inbox retention rules and DOES travel as a session artifact, but its `weights_path` reference points into the excluded `~/.allbert/adapters/` tree, so a peer machine receiving the approval markdown sees the activation history without the weights themselves. The peer machine can re-train against the recorded corpus digest and produce a structurally equivalent adapter; activation against the peer's adapter is then an explicit local action.

### Opt-in inclusion

`profile export --include-adapters` (a new flag in the v0.13 release) lets an operator who explicitly wants a full adapter copy include `~/.allbert/adapters/installed/` and the active-adapter pointer in the export. The default remains exclusion. Including adapters does not include training-run staging or incoming external adapters.

The export manifest reports the included adapter count and total bytes when `--include-adapters` is set, so the operator can confirm size before transmitting.

### Operator visibility

`allbert-cli profile export --dry-run` lists what is included and what is excluded. v0.13 updates the dry-run output to name the adapter directories explicitly so an operator never wonders why their adapters did not travel.

## Consequences

**Positive**

- Profile export stays a markdown-and-text-first transport, not a multi-GB binary courier.
- Cross-host adapter compatibility issues are avoided by default.
- The continuity contract stays predictable: derived artifacts that depend on local-host hardware do not travel.

**Negative**

- Operators wanting a full mirror across two machines need either `--include-adapters` or an out-of-band copy. Acceptable: the flag exists; the dry-run output names the exclusion.
- Re-training across machines requires duplicate compute. Acceptable: the corpus determinism (same inputs → same digest) makes this auditable and reviewers can compare the resulting adapter approvals.

**Neutral**

- Future hosted adapter storage (deferred beyond v0.13) would have its own continuity story.
- The exclusion list is closed in v0.13; adding a new adapter sub-directory in a later release requires explicitly choosing inclusion or exclusion.

## References

- [docs/plans/v0.13-personalization.md](../plans/v0.13-personalization.md)
- [ADR 0061](0061-local-only-continuity-posture.md) — amended by this ADR (extends the derived/host-specific exclusion list to adapters).
- [ADR 0081](0081-durable-session-trace-artifacts-and-replay-envelope.md)
- [ADR 0084](0084-personality-adapter-job-is-a-learning-job-with-an-owned-trainer-trait.md)
- [ADR 0086](0086-adapter-approval-is-a-new-inbox-kind.md)
