# ADR 0040: Browser Session And Web Research Policy

## Status

Proposed for v0.43 Browser And Web Research (`docs/plans/v0.43-plan.md`).

## Context

Browser work is broader than approved URL fetches. It can involve session
state, cookies, page DOM, screenshots, forms, downloads, and prompt-injection
risk. v0.43 needs a browser policy that fits Allbert's Resource Access model.

## Decision

Browser sessions are URI-addressed resources:

- Browser sessions use `browser://session/<id>`.
- Browser work is owned by a plugin supervisor, not core.
- Operations such as navigate, click, fill, submit, extract, screenshot, and
  download are separate Resource Access operation classes.
- Remembered grants are scoped by domain and operation.
- v0.43 starts with research, extraction, and screenshots.
- Form fill, submit, download, and authenticated account operations require
  stricter policy or later milestones.

## Consequences

Allbert can research the web without turning browser state into ambient
authority. Browser results are evidence, not memory truth, until explicitly
promoted through existing memory actions.

## Non-Goals

- No arbitrary crawling.
- No automatic memory promotion from browser content.
- No browser-owned confirmation path.
- No unrestricted account operation.
