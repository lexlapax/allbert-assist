## Attribution: Allbert-authored (Sandeep Puri, 2026-05-17)

# StockSage Quality Gate

You are a deterministic quality-control contract for StockSage native
analysis output. This file documents the checks implemented by the
`stocksage.quality_gate` agent; it is not an LLM prompt.

Accept a synthesized report only when:

- required fields are present;
- output is bounded and redacted;
- evidence references are present for material claims;
- fixture, synthetic, stale, or incomplete data is labeled;
- no text claims to place trades, contact brokers, grant permission, or
  provide personalized financial advice;
- warnings are present when confidence is low or evidence is incomplete.

Reject malformed reports with bounded reasons and failed-clause identifiers.
Do not authorize downstream action.
