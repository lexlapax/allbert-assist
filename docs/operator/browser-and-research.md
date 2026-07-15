# Browser And Web Research

Allbert ships a policy-bounded browser plugin (introduced in v0.43) for rendered page
research, screenshots, and bounded HTML/text/markdown/PDF extraction. It
controls local headless Chromium through the reviewed plugin-owned Playwright
bridge. Browser content is evidence only; it never grants permission or
bypasses confirmation.

## Enable And Doctor

```sh
mix allbert.settings set browser.enabled true
mix allbert.browser doctor
```

The doctor records a redacted live-check envelope under
`<ALLBERT_HOME>/cache/browser/doctor/state.json`. Session start fails closed
when the doctor has never succeeded, is stale, or reports anything other than
`ok`. The Playwright bridge dependencies live under
`plugins/allbert.browser/priv/playwright_bridge/`; package managers are not run
during plugin discovery or browser action execution.

On failure, the persisted doctor state includes a stable `error_category` for
operator troubleshooting: `node_unavailable`, `playwright_bridge_missing`,
`playwright_bridge_start_failed`, `bridge_timeout`, `bridge_exited`,
`bridge_protocol_error`, `browser_live_check_timeout`,
`chromium_launch_failed`, `playwright_runtime_error`, or
`unknown_browser_doctor_error`.

## Research CLI

```sh
mix allbert.browser research "https://example.com" --extract-format=text
```

The research helper runs the same registered-action workflow as the runtime:
doctor, start an approved CLI session, navigate with browser policy, extract,
and close the session in cleanup. `--extract-format` accepts `text`,
`markdown`, `html`, or `pdf`.

## Actions

| Action | Purpose |
|---|---|
| `browser_doctor` | Verify the local Playwright/Chromium bridge and persist redacted status. |
| `browser_start_session` | Confirm and start an ephemeral session. |
| `browser_navigate` | Confirm or use a remembered per-domain grant, then navigate. |
| `browser_extract` | Extract bounded `html`, `text`, `markdown`, or simple PDF text-layer content. |
| `browser_screenshot` | Write a redacted screenshot artifact into browser cache. |
| `analyze_browser_screenshot` | Analyze a cached `screenshot_ref` from `browser_screenshot` through the vision path (reuses the cached image; does not capture the OS screen). |
| `browser_click` | Confirm a selector click with a bounded visible-label preview. |
| `browser_fill` | Denied by default; after explicit opt-in, confirm a form field fill with value redaction. |
| `browser_download` | Denied by default; after explicit opt-in, confirm a bounded browser download request. |
| `browser_list_sessions` | List sessions in the current runtime process. |
| `browser_close_session` | Close a session in the current runtime process. |
| `browser_sweep_cache` | Remove expired browser cache artifacts. |
| `browser_research_handoff` | Agent-only handoff for page summary, render, and extract prompts. Raises one up-front research consent confirmation; your approval records the site's navigation grant and runs the research delegate once to completion. The action itself grants no authority. |

The `mix allbert.browser sessions list` and `sessions close <id>` helpers call
the same registered actions for sessions visible to the current node.
Session list, close, and cache sweep use the browser read/extract permission
floor because they operate on already-created browser session/cache artifacts;
they do not authorize navigation or page interaction.

When `browser.navigation.allowed_domains` is non-empty, navigation is limited
to those hosts. When it is empty, normal SSRF/private-network policy still
applies and public hosts are allowed subject to confirmation/grants.

As of v0.46, prompts in the locked research corpus (`research <topic>`,
`research <URL> and summarize`, and `summarize the research on <topic>`)
route to the `research.specialist` delegate when research is enabled. The
browser handoff remains advisory and browser-specific; it does not own those
research phrases.

## Cache And Evidence

Extraction and screenshot artifacts live under:

```text
<ALLBERT_HOME>/cache/browser/<session_id>/
```

The workspace Browser panel renders recent cached extraction previews and
screenshot links. Raw page/PDF content belongs in cache, not traces.

Browser sessions are bounded by `browser.session.max_lifetime_ms`,
`browser.session.idle_timeout_ms`, and `browser.session.max_concurrent`.
Browser cache retention honors both `browser.cache.max_age_ms` and
`browser.cache.max_bytes`; the plugin supervisor contributes the paused sweep
job idempotently.

## Redaction And Denials

All traces, audits, CLI output, and workspace summaries must redact cookies,
`Authorization`, URL userinfo, and credential-shaped query values. Form fill
and downloads remain denied by default in v0.43; opt-in changes the floor only
to confirmation, never unconditional allow.
