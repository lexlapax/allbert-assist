# ADR 0086: Adapter approval is a new inbox kind

Date: 2026-04-25
Status: Accepted

Amends: [ADR 0060](0060-approval-inbox-is-a-derived-cross-session-view.md)

## Context

v0.13 ships the second self-change artifact kind that needs an operator approval gate: trained LoRA/adapter weights produced by `PersonalityAdapterJob`. The v0.8 approval inbox (ADR 0060) already handles `tool-approval`, `cost-cap-override`, `job-approval`, and (via ADR 0073) `patch-approval`.

ADR 0073 set the precedent for adding a kind: reuse the inbox file layout, add kind-specific frontmatter fields, render with a per-kind summary, and tune resolution semantics where they differ from existing kinds.

Adapter approvals are different in shape from the existing kinds in three ways:

1. **Artifact size.** Adapter weights are tens of megabytes to gigabytes. They cannot be inlined; they must be referenced by path the same way ADR 0073 references diff artifacts.
2. **Activation is a separate verb.** Like patch-approval, accepting an adapter approval does NOT activate the adapter; activation is a separate explicit operator command. This preserves the no-auto-swap posture from ADR 0068 and matches operator muscle memory.
3. **Eval data attaches to the approval.** Reviewers who are not ML engineers need a structured eval summary at the approval surface so they can decide without reading loss curves.

## Decision

ADR 0060 is amended to add a fifth inbox kind: `adapter-approval`.

### File layout

A `adapter-approval` lives at the standard ADR 0056 / ADR 0060 path:

```
~/.allbert/sessions/<sid>/approvals/<aid>.md
```

Frontmatter mirrors existing approval kinds with these additional fields:

```yaml
kind: adapter-approval
adapter_id: 20260501-personality-1
provenance: self-trained          # self-trained | external
trainer_backend: mlx-lm-lora      # mlx-lm-lora | llama-cpp-finetune | external
base_model:
  provider: ollama
  model_id: gemma4
  model_digest: <sha256>
training_run_id: 20260501-1842-lora
corpus_digest: <sha256-of-canonicalised-corpus>
artifact_root: /Users/.../.allbert/adapters/runs/20260501-1842-lora/
weights_path: /Users/.../.allbert/adapters/runs/20260501-1842-lora/adapter.safetensors
weights_format: safetensors-lora  # safetensors-lora | gguf-lora
weights_size_bytes: 134217728
hyperparameters:
  rank: 8
  alpha: 16
  learning_rate: 0.0001
  max_steps: 200
  batch_size: 4
  seed: 42
resource_cost:
  compute_wall_seconds: 932
  peak_resident_mb: 6144
  usd: 0.0
eval_summary:
  golden_pass_rate: 0.92            # against ~/.allbert/adapters/evals/golden.jsonl
  loss_final: 0.81
  loss_curve_path: /Users/.../.allbert/adapters/runs/20260501-1842-lora/loss-curve.txt
  behavioral_diff_path: /Users/.../.allbert/adapters/runs/20260501-1842-lora/behavioral-diff.md
overall: ready-for-review           # ready-for-review | needs-attention
```

`overall = ready-for-review` only when training completed without errors, the eval golden_pass_rate is at or above the configured threshold (`learning.adapter_training.min_golden_pass_rate`, default `0.85`), and the resource_cost stayed within the per-run compute cap. Any failure marks `needs-attention`; activation paths refuse `needs-attention` adapters and require an explicit override flag (`adapters activate <id> --override`).

### Weights stay out of the approval markdown

Adapter weights are referenced by `weights_path`, never inlined. The eval markdown (`behavioral-diff.md` and ASCII `loss-curve.txt`) lives alongside the weights in the run directory and is referenced by path so the inbox view stays compact. This matches the ADR 0073 pattern for diffs and the v0.8 image-attachment pattern for media.

### Renderer

`allbert-cli inbox show <aid>` for an `adapter-approval` surfaces:

```
Adapter approval <aid>
Provenance:   self-trained
Trainer:      mlx-lm-lora
Base model:   ollama / gemma4
Run id:       20260501-1842-lora
Corpus:       <digest> (12 durable, 47 facts, 8 episode summaries, 24576 input bytes)
Hyperparams:  rank=8 alpha=16 lr=0.0001 steps=200 batch=4
Compute:      932s wall, peak 6144 MB
Eval:         golden 92% (134/146)  loss 0.81  see behavioral-diff.md
Overall:      ready-for-review

To view the full eval summary:
  allbert-cli adapters eval <aid>

To view the loss curve:
  allbert-cli adapters loss <aid>

To activate (operator action — accept does not activate):
  allbert-cli inbox accept <aid>
  allbert-cli adapters activate <adapter_id>
```

The renderer never inlines binary weights, never inlines full eval traces, and never inlines training logs. Each detail is one command away.

### Resolution semantics (where this differs from other kinds)

- **`inbox accept <aid>`** marks the adapter approved for activation, records approver identity + reason, and **does nothing else**. Specifically: it does NOT activate the adapter and does NOT change any active-adapter pointer. The operator is directed to `allbert-cli adapters activate <adapter_id>` as the next step (per ADR 0085).
- **`inbox reject <aid>`** marks the adapter rejected, records rejector identity + reason, and (by default) deletes the run directory at `artifact_root`. The deletion is configurable via `learning.adapter_training.keep_rejected_runs` (default `false`); when `true`, the run is preserved for forensic review and operators must `adapters gc` to reclaim disk later.

Both verbs use the same vocabulary as other inbox kinds.

### Identity-scoped resolution

Per ADR 0060, any surface belonging to the approval's identity (per ADR 0058) can resolve. An adapter approval emitted from a scheduled training job can be accepted from REPL or Telegram if the operator's identity covers them. Approver channel and sender are recorded on the resolution entry for audit.

### External adapters

Operator-dropped adapters under `~/.allbert/adapters/incoming/` route through the same `adapter-approval` kind with `provenance: external`. The renderer omits trainer-backend and corpus-digest fields (replaced by `source: <path>`), surfaces a privacy notice (the operator vouches for the adapter's training data provenance), and otherwise reuses the same activation flow.

### Retention

Adapter approvals follow the same retention as other inbox kinds: pending and resolved approvals within `channels.approval_inbox_retention_days` (default 30, ADR 0060). Rejected runs that were preserved (per `keep_rejected_runs`) remain on disk past the inbox retention window and are reclaimed only by `allbert-cli adapters gc`.

### What this ADR explicitly does NOT change

- The ADR 0060 inbox file layout (paths, identity scoping, retention defaults) — `adapter-approval` is additive.
- The ADR 0056 cross-session resolution behavior — `adapter-approval` resolves the same way other kinds do.
- The relationship between inbox accept and activation — activation remains a separate operator command (ADR 0085).
- The patch-approval kind — `adapter-approval` is a sibling, not a subtype.

## Consequences

**Positive**

- Operators get adapter review through the same surface they already use for tool, cost-cap, job, and patch approvals — no new command vocabulary.
- Weights live as artifacts, not inline, so inbox storage stays tractable even with frequent training.
- The renderer's "summary first, full detail on demand" shape scales cleanly to multi-GB adapters.
- Accept/activate separation keeps the no-auto-swap posture intact.

**Negative**

- A fifth inbox kind adds rendering surface in the inbox CLI. Acceptable: rendering is per-kind anyway, and the patterns from cost-cap-override, job-approval, and patch-approval already established that inbox rendering is kind-aware.
- Operators may expect `inbox accept` to actually activate the adapter. Documentation in `docs/operator/personalization.md` covers this; the renderer message also calls it out.

**Neutral**

- ADR 0060 gains a banner noting this amendment. The amendment chain is now: ADR 0056 → amended by ADR 0060 → amended by ADR 0073 (patch-approval) → amended by this ADR (adapter-approval). ADR 0056's file-format-of-record status is unchanged; this ADR only adds a new `kind` value.
- Future inbox kinds can follow the same additive pattern.

## References

- [docs/plans/v0.13-personalization.md](../plans/v0.13-personalization.md)
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0056](0056-async-confirm-is-a-suspend-resume-turn-state.md)
- [ADR 0058](0058-local-user-identity-record-unifies-channel-senders.md)
- [ADR 0060](0060-approval-inbox-is-a-derived-cross-session-view.md) — amended by this ADR (adds `adapter-approval` kind).
- [ADR 0073](0073-rebuild-patch-approval-is-a-new-inbox-kind.md)
- [ADR 0080](0080-self-change-artifacts-share-approval-provenance-and-rollback-envelope.md)
- [ADR 0084](0084-personality-adapter-job-is-a-learning-job-with-an-owned-trainer-trait.md)
- [ADR 0085](0085-adapter-activation-is-local-only-and-base-model-pinned.md)
