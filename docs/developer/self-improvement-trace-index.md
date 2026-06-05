# Self-Improvement Trace Index

Status: v0.47 M1 implemented.

This document is the v0.47 M1 trace-pattern inventory and privacy policy for
`AllbertAssist.SelfImprovement.TraceIndex`.

## Activation

The trace index is disabled unless both settings are enabled:

- `self_improvement.enabled`
- `self_improvement.trace_index.enabled`

Both default to `false`. When either flag is disabled,
`TraceIndex.query/1` returns no patterns and does not read trace files.
`self_improvement.schema_version` is read-only. Bounded settings cap indexed
entries, minimum repetitions, open suggestions, suggestion TTL, and open
drafts.

## Indexed Signals

The index reads existing markdown traces under
`<ALLBERT_HOME>/memory/traces/` and compiles these bounded pattern types:

- `repeated_prompt`: repeated redacted prompt text.
- `action_chain`: repeated action-name sequences from the trace Actions
  section, with `Selected action` as a fallback.
- `correction`: repeated prompts containing bounded correction language such
  as "actually", "fix that", "try again", or "wrong".
- `failed_intent`: repeated denied, failed, unsupported, or missing-action
  turns.

The index records counts, redacted samples where useful, action names,
per-pattern scope, and relative source references such as
`traces/<file>.md`. It does not write derived index files.

## Privacy Policy

The trace index adds no new source of truth and no new exposure beyond stored
traces. It inherits the v0.40-v0.43 trace redaction posture and re-applies the
runtime redactor before storing prompt samples or deriving prompt
fingerprints. Older or hand-written traces that still contain secret-shaped
values are therefore redacted again before pattern output is returned.

Trace retention is unchanged. Existing trace files remain governed by the
trace-memory retention policy; the compiled index is in-memory and
request-scoped.

`TraceIndex.query/1` is scoped by optional `user_id` and `app_id` filters. A
pattern returned for a scoped query contains only source references whose
trace metadata matches that user and app. If no scope is supplied, returned
patterns still include their observed `user_ids` and `app_ids` so callers can
render or filter them without guessing.

The index is read-only. Counts, repeated use, correction language, failed
intents, and action chains are advisory discovery evidence only. They grant no
permission, enable no skill or workflow, create no plugin, change no setting,
and do not bypass Security Central or confirmation.
