# Browser And Web Research

Allbert v0.43 ships a policy-bounded browser plugin for rendered page
research, screenshots, and bounded HTML/text/markdown/PDF extraction. Browser
content is evidence only; it never grants permission or bypasses confirmation.

## Enable And Doctor

```sh
mix allbert.settings set browser.enabled true
mix allbert.browser doctor
```

The doctor records a redacted live-check envelope under
`<ALLBERT_HOME>/cache/browser/doctor/state.json`. Session start fails closed
when the doctor has never succeeded, is stale, or reports anything other than
`ok`.

## Actions

| Action | Purpose |
|---|---|
| `browser_start_session` | Confirm and start an ephemeral session. |
| `browser_navigate` | Confirm or use a remembered per-domain grant, then navigate. |
| `browser_extract` | Extract bounded `html`, `text`, `markdown`, or simple PDF text-layer content. |
| `browser_screenshot` | Write a redacted screenshot artifact into browser cache. |
| `browser_click` | Confirm a selector click with a bounded visible-label preview. |
| `browser_list_sessions` | List sessions in the current runtime process. |
| `browser_close_session` | Close a session in the current runtime process. |
| `browser_sweep_cache` | Remove expired browser cache artifacts. |

The `mix allbert.browser sessions list` and `sessions close <id>` helpers call
the same registered actions for sessions visible to the current node.

## Cache And Evidence

Extraction and screenshot artifacts live under:

```text
<ALLBERT_HOME>/cache/browser/<session_id>/
```

The workspace Browser panel renders recent cached extraction previews and
screenshot links. Raw page/PDF content belongs in cache, not traces.

## Redaction And Denials

All traces, audits, CLI output, and workspace summaries must redact cookies,
`Authorization`, URL userinfo, and credential-shaped query values. Form fill
and downloads remain denied by default in v0.43.
