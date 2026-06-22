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
- `eval/operator-actions/` covers planned v0.56 operator-action names before
  implementation makes them available.
- `eval/tui-slash/` covers TUI slash commands. Slash lines are never model turns.
- `eval/baseline.yaml` records the M2 BEFORE result. It is evidence, not a
  corpus case, and the loader intentionally skips it.

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
Use `negative: true` when a phrase must not execute the named action or any
operator/internal action. For slot checks, use a literal value or a list entry
when presence is enough.

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

`eval/baseline.yaml` is a snapshot of the M2 BEFORE run. It may fail the final
gate. Later milestones compare against it so descriptor changes cannot regress
accuracy or negative-route behavior while moving toward the v0.56 release gate.
