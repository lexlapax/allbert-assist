# Intent Eval Fixtures

This directory contains the committed routing corpus for the v0.56 intent eval
harness. It exists to make routing accuracy, clarification behavior, and
negative-route guarantees deterministic enough for CI and release gates.

The release gate reads only committed YAML files under `eval/`, excluding
`eval/baseline.yaml`. Runtime/operator captures live under Allbert Home until a
developer reviews and promotes them into this fixture tree.

## Layout

- `eval/<domain>/*.yaml` contains one or more corpus cases for a product or
  safety domain.
- `eval/negative-internal/` covers internal action names that must never be
  natural-language route targets.
- `eval/negative-doctor/` covers doctor/operator inspection phrasing.
- `eval/negative-operator/` covers planned v0.56 operator-action names before
  implementation makes them available.
- `eval/negative-slash/` covers TUI slash commands. Slash lines are never model turns.
- `eval/baseline.yaml` records the current v0.56 release ratchet baseline. It
  is evidence, not a corpus case, and the loader intentionally skips it.

Current fixture domains/directories:

```text
adversarial, answer, apps, browser, calendar, channels, confirmations,
cross-surface, email, external, github, image, marketplace, mcp, memory, model,
negative-doctor, negative-internal, negative-operator, negative-slash, none,
notes, objectives, packages, plan-build, plugins, public-protocol, research,
resources, settings, shell, skills, stocks, voice
```

Use the closest existing domain. Add a new domain only when the behavior has a
meaningfully different routing contract, not just a new action name.

## Case Shape

Each YAML file may be one case map or a top-level `cases:` list. Keep fields
small and redacted.

```yaml
schema_version: 1
id: memory-remember-001
domain: memory
surface: any
utterance: remember that I prefer concise release notes
expected:
  kind: execute
  action: append_memory
  slots: {}
negative: false
holdout: false
rationale: Covers a direct memory write request.
```

Valid `expected.kind` values are `execute`, `clarify`, `answer`, and `none`.
Use `negative: true` when a phrase must not execute. This defaults to
`negative_mode: no_execute`, which means **any** execute outcome is a violation.
Use the narrower `negative_mode: forbidden_action` only for a deliberate sibling
confusion probe where executing a specific `forbidden_action` is the only failure.
For slot checks, use a literal value or a list entry when presence is enough.

### Surfaces

`surface` scopes when a case participates in cross-surface runs. Valid values:

```text
any, web, tui, telegram, discord, slack, matrix, whatsapp, signal, email
```

- `any` is the default and runs in every deterministic surface pass.
- A surface-specific value runs for `any` plus that named surface only.
- Surface affects delivery context, not authority. The same utterance should
  select the same action across surfaces unless the case explicitly proves a
  surface-only safety rule.
- TUI slash lines belong in `negative-slash/`; they are command lines, not model
  turns, and must not become routable natural-language actions.

### Expected Kinds

- `execute`: the router should select `expected.action`. This kind requires an
  `action` field. Add `slots` when the case proves slot extraction.
- `clarify`: the router should ask a follow-up question instead of executing.
  Use for missing required slots or genuinely ambiguous sibling actions.
- `answer`: the request should be answered conversationally, not routed to an
  action. Do not use this for "what do I have/show/list/read" requests when a
  retrieval action exists.
- `none`: no available action or conversational answer should handle the
  utterance.

For `negative: true`, the scorer checks forbidden execution before normal accuracy:

- default / `negative_mode: no_execute`: any `execute` outcome is a violation.
- `negative_mode: forbidden_action`: only executing `forbidden_action` (or
  `expected.action` when `forbidden_action` is omitted) is a violation.

Operator/internal/doctor/slash-command cases must use the default no-execute mode.
Non-execute outcomes are acceptable unless the case also has a stricter
`expected.kind` assertion.

Slot expectations support two forms:

```yaml
slots:
  ticker: AAPL       # exact value required
```

```yaml
slots:
  - body             # presence required; value may vary
```

## Adding Cases

1. Prefer adding one small YAML file in the closest existing domain.
2. Use a stable id: `<domain>-<behavior>-NNN` or
   `internal-<action>-negative-NNN`.
3. Use real operator phrasing, not synthetic action-name strings, except for
   explicit negative probes that prove names do not become routable.
4. Keep secrets, endpoints, transcripts, and user data out of committed cases.
5. Run the focused corpus/eval tests before relying on the case:

   ```sh
   MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/intent/eval
   ```

6. If the new case comes from operator validation, preserve raw evidence only in
   the durable local evidence directory and commit a sanitized case here.

## Baseline Semantics

`eval/baseline.yaml` is the committed v0.56 release ratchet baseline, generated
from the deterministic runner with `mix allbert.intent eval baseline`. It should
match the full committed corpus and pass the gate. Future descriptor changes
compare against it so routing accuracy, slot accuracy, clarify-vs-execute
behavior, and negative-route behavior cannot silently regress.

Historical note: the original M2 BEFORE baseline was a failing 237-case snapshot
used during implementation to measure progress. It was replaced before tagging by
the release baseline (`v056-release-baseline`, 254 cases, 1.0 accuracy after M14b). The
legacy live-bench anchor fixture still exists under `test/fixtures/intent/golden`;
it is intentionally separate from this deterministic release-gate corpus and is
loaded through a literal data-only parser, never `Code.eval_file/1`.
