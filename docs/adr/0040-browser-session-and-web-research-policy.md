# ADR 0040: Browser Session And Web Research Policy

## Status

Proposed for v0.43 Browser And Web Research (`docs/plans/v0.43-plan.md`).

M5 closeout flips this line to `Accepted for v0.43 Browser And Web
Research` per the §"M5 Closeout Discipline" checklist in the plan.

## Context

Allbert has so far treated remote content as either a confirmed HTTP/service
fetch (v0.10 `external_network_request`, ADR 0011) or as a v0.11-owned
inert/unsupported workflow (`summarize_url`, `inspect_document`). Both paths
deliberately stay below the layer where a real browser runtime is involved.

Browser work is materially broader than HTTP fetches:

- Browser sessions hold state: cookies, local storage, IndexedDB, service
  workers, in-flight network sockets, open documents, and the page DOM.
- Each navigation can trigger many subresources (CSS, JS, images, XHR/fetch,
  WebSocket, beacons) under the browser's network stack, not Allbert's
  `External.HttpPolicy` (ADR 0011).
- Operations such as click, fill, submit, download, and "evaluate JS" are
  qualitatively different from a `GET` and carry distinct risk profiles.
- Screenshots can capture sensitive on-screen state (input field values,
  authenticated session UI, OTP codes, password autofill placeholders).
- Bounded document extraction (HTML, markdown, plain text, PDF) brings parser
  attack surface that Allbert does not currently host.
- Page content is untrusted: HTML, comments, hidden DOM nodes, alt text, and
  embedded PDF text are common prompt-injection vectors against agents.
- Browser drivers (Playwright, Wallaby/ChromeDriver, Puppeteer, raw CDP) are
  themselves supply-chain risk: a malicious driver binary or transport version
  controls every subsequent operation.

Current external research reinforces the boundary:

- OWASP SSRF and AI agent guidance both call out browser-class fetches as a
  separate risk surface from server-side HTTP because the browser executes
  attacker-controlled JS and follows attacker-controlled redirects.
- OWASP prompt-injection guidance treats fetched HTML/PDF text as untrusted
  data, not as instructions.
- MCP security best practice (per ADR 0038) is to keep server-supplied text
  descriptive, not authoritative — the same rule applies to page content.
- Anthropic and OpenAI agent docs separate browser/computer-use capabilities
  from network and tool-call permissions, and require explicit human approval
  for navigation scope, downloads, form submission, and account operation.
- Major modern browsers expose request interception (Chromium CDP
  `Fetch.enable`, Playwright `route`, Puppeteer `setRequestInterception`),
  which is the mechanism by which subresource policy is actually enforced.

v0.43 needs a browser policy that fits Allbert's Resource Access Security
Posture (ADR 0012), the URI-first identity decision (ADR 0013), the plugin
contract (ADR 0017), the action DSL (ADR 0027), the capability-gap vocabulary
(ADR 0033), the provider-doctor contract (ADR 0047), and the development-lane
contract (ADR 0049) — without growing core dependencies, granting ambient
authority, or making browser content authoritative.

## Decision

Browser sessions are URI-addressed resources owned by a plugin, with
per-operation safety floors, per-domain remembered grants, and a hard rule that
page content is descriptive, never authoritative.

### Identity

- Browser sessions are identified by `browser://session/<id>`.
- Navigated URL targets keep their native `https://` or explicitly allowed
  `http://` URI. The session URI is the lifecycle/ownership identity; the
  navigated URL is the operation target. (ADR 0013 amendment.)
- `<id>` is opaque, server-generated, and never echoes operator-supplied or
  remote text. `<id>` is not derived from the navigated URL.
- A session URI does not authorize navigation; navigation is authorized by the
  per-domain grant on the target URL.

### Ownership

- Browser process ownership lives in the plugin supervisor
  (`./plugins/allbert.browser/`), under `AllbertBrowser.Supervisor`. Core never
  spawns an unbounded browser. The plugin is a reviewed source-tree plugin and
  is compiled through the existing shipped-plugin path; plugin discovery never
  runs a package manager or installer.
- Each active session is a supervised process (`AllbertBrowser.Session`) with a
  bounded lifetime, idle timeout, and `max_concurrent` session cap from
  Settings.
- The driver binary path, Node/Playwright bridge version, Chromium
  availability, OS support, PDF parser availability, and capability set are
  surfaced through a `browser_doctor` action that follows ADR 0047's redacted
  return shape. The doctor is the seam where supply-chain provenance is
  checked; sessions refuse to start when the doctor reports an unverified or
  missing dependency.
- **Doctor live verification (v0.42 R2 lesson — structure-only checks
  miss broken bridges).** `browser_doctor` does not stop at file-exists
  / version-string checks. It launches one ephemeral Chromium context
  through `AllbertBrowser.Driver`, navigates to `about:blank`, closes
  the page, and records `last_verified_at: DateTime.utc_now()` plus
  `live_check_status` (`:ok`, `:degraded`, `:failed`, `:unavailable`)
  on the redacted result. Persistence lives under
  `<ALLBERT_HOME>/cache/browser/doctor/state.json` so
  `browser_start_session` can read it.
- **Session-start consults the doctor (v0.42 R2 lesson).**
  `browser_start_session` fails closed before any driver work when the
  doctor has never been run successfully, the last `live_check_status`
  is not `:ok`, or the last `last_verified_at` is older than
  `browser.doctor.max_age_ms` (default 24h). The failure surface names
  the unmet condition so the operator can re-run
  `mix allbert.browser doctor` and retry.

### Operation classes

The closed `AllbertAssist.Resources.OperationClass` vocabulary grows by six
entries:

- `:browser_navigate` (access mode `:fetch`)
- `:browser_extract` (access mode `:read`)
- `:browser_screenshot` (access mode `:read`)
- `:browser_interact` (access mode `:execute`) — click and equivalents
- `:browser_form_fill` (access mode `:write`) — denied default
- `:browser_download` (access mode `:write`) — denied default

`@origin_kinds` grows by `:browser_session`. `@scope_kinds` grows by
`:browser_session` for in-session refs. Per-domain navigation grants reuse the
existing `:url_prefix` scope kind on the navigated target URL.

Cross-operation grant authority is forbidden:

- a `:browser_navigate` grant does not authorize `:browser_form_fill`,
  `:browser_download`, or `:browser_interact`;
- a `:summarize_url`, `:inspect_document`, or `:external_service_request` grant
  does not authorize `:browser_navigate`;
- a `:browser_extract` grant authorizes only further read of the
  already-loaded page within the same session and the same domain.

### Permission classes and safety floors

`AllbertAssist.Security.Policy` adds:

| Permission | Default decision | Safety floor |
|---|---|---|
| `:browser_session_start` | `:needs_confirmation` | `:needs_confirmation` |
| `:browser_navigate` | `:needs_confirmation` | `:needs_confirmation` |
| `:browser_extract` | `:allowed` | `:allowed` |
| `:browser_screenshot` | `:allowed` | `:allowed` |
| `:browser_interact` | `:needs_confirmation` | `:needs_confirmation` |
| `:browser_form_fill` | `:denied` | `:needs_confirmation` |
| `:browser_download` | `:denied` | `:needs_confirmation` |

Settings can tighten any class but cannot loosen a safety floor. Form fill and
download default to denied; explicit operator opt-in may raise them only to
confirmation, never to unconditional allow. `BrowserClick` and `BrowserFill`
ship in v0.43 only with restrictive policy so the action surface is complete
and inspectable; broad form-fill/submit/download is a later milestone.

### Per-domain remembered grants

- Grants are scoped per **domain + operation** using the existing
  `:url_prefix` scope kind on the canonical `https://<host>/` (or explicitly
  allowed `http://<host>/`) URI plus the new operation classes.
- Session URIs (`browser://session/<id>`) are ephemeral and are not grant
  authority; remembered grants reference the domain, never the session.
- `BrowserNavigate` looks up an existing grant before creating a new
  confirmation; the lookup follows the v0.10 M11 pattern used by external
  request, online skill source, and package install.
- Redirect chains that leave the granted domain fail closed: the request is
  not silently approved against the new host.

### Network and subresource policy

The browser driver makes network requests at its own layer; a v0.43 browser
navigation preflight helper reuses `External.HttpPolicy`'s **top-level
navigation URL** checks, and a parallel `AllbertBrowser.NetworkPolicy` enforces subresource and
redirect-chain rules via the driver's request-interception API:

- top-level navigation: SSRF/host-rule/scheme checks identical to
  the existing `External.HttpPolicy` posture; redirects denied by default
  (must be re-confirmed against the new domain);
- top-level navigation URL credential rejection (extending v0.42 R9):
  the M1-shipped `External.HttpPolicy` extension rejects URL userinfo
  (preserved unchanged) plus query parameter names matching the v0.42
  R9 credential-name set (`token`, `api_key`, `key`, `secret`,
  `password`, `bearer`, `access_token`, `auth`, case-insensitive) and
  the opaque-blob heuristic for credential-shaped values. Browser
  navigation, v0.10 `external_network_request`, and v0.42 MCP server
  connect all inherit the rejection. Operators who need credentials in
  a URL move them to `auth_ref` or `secret://` substitution;
- subresources: same SSRF/private-network/loopback denial; allowed only if the
  origin matches the navigated domain or an operator-configured CDN allowlist;
- bounded timeouts and bounded response sizes per resource and per page;
- no WebSocket, no service worker registration, no background sync at v0.43.

### Extraction

- Extractors are bounded: max bytes per page, max pages per PDF, max parse
  time. Caps are settings-driven and surface in confirmations and traces.
- PDF parsing uses a doctor-verified bounded local text-layer parser path
  implemented inside the browser plugin. It ignores embedded JavaScript,
  embedded forms, and external references (no follow-on fetch), and fails
  closed for encrypted, scanned/image-only, malformed, or unsupported PDFs.
  No package manager, external installer, or host parser subprocess runs during
  plugin activation or release tests. Byte/page caps, malformed-input
  handling, and fail-closed behavior are part of the v0.43 extractor contract.
- Extracted text is descriptive, not authoritative: extraction output never
  steers agent behavior and is treated as user-readable evidence only.

### Screenshots

- Screenshots are bounded (max bytes, no full-page by default to limit
  credential capture).
- Known credential-bearing input types (`type=password`, `autocomplete=otp`,
  `autocomplete=cc-number`) are redacted before the bitmap is encoded.
- Cookies, Authorization headers, full URLs with credential userinfo, and
  session storage are redacted from any trace/audit metadata associated with
  the screenshot.

### Profile and persistence

- v0.43 uses ephemeral browser profiles only. Cookies, local storage, and
  cache are discarded on session close.
- Persistent profiles, login flows, and authenticated session reuse are
  parked (see `docs/plans/future-features.md`).

### Trace and audit

- Browser actions emit trace/audit metadata redacted by
  `AllbertAssist.Security.Redactor`: cookies, Authorization, full URLs with
  credentials, and known sensitive headers are scrubbed; query strings keep
  parameter names but redact values for known credential parameter names.
- Trace records carry the action name, redacted target URL, operation class,
  byte/page counts, success/failure, and confirmation id. Raw HTML/PDF/text
  bodies and raw screenshots are not stored under `memory/traces/`; they are
  referenced by content-addressable paths under
  `<ALLBERT_HOME>/cache/browser/<session_id>/` with retention bounded by
  settings.
- Trace shape is pattern-mineable for v0.47 self-improvement: the redacted
  envelope is mineable; raw content is not.

### Workspace rendering

- Browser results render through a workspace panel contributed by the
  `allbert.browser` plugin via the v0.27 SurfaceProvider contract. The panel
  shows extracted text, screenshots (as links to the cache path), and
  trace/audit metadata.
- The panel never calls the browser driver directly; every effect goes
  through `Actions.Runner.run/3`, Security Central, and confirmations.

## Consequences

- Allbert can research the web through a bounded, plugin-owned browser
  without turning browser state into ambient authority.
- ADR 0013 grows a `browser://session/<id>` scheme entry; `ResourceURI` gains
  scheme-specific normalization for the new identity.
- ADR 0012's Resource Access posture extends to browser operations without
  inventing a parallel security model. Browser grants live in the same
  `resource_grants.remembered` store, matched by the same `Grants` rules.
- ADR 0017's plugin contract receives the first plugin whose contributions
  include long-lived OTP processes (browser sessions) rather than only
  metadata, panel surfaces, and per-call actions; the plugin child supervisor
  pattern is exercised end-to-end.
- v0.10's `external_network_request` and v0.11's `summarize_url`/
  `inspect_document` remain. v0.43 does not retire them. `BrowserExtract` is
  the graduated path; the routing decision (browser vs HTTP) is recorded in
  v0.43 §"Browser-fetch vs HTTP-fetch routing".
- v0.45 Plan/Build can compose browser actions as objective/workflow steps
  through the same registered-action boundary; ADR 0041 needs no amendment
  for v0.43.
- v0.47 self-improvement can mine v0.43 trace envelopes (redacted) as one
  pattern source; raw browser content remains out of bounds.
- v0.44 channel approval-primitive amendment (ADR 0016) must accommodate
  browser confirmations: navigation approvals are expressible as
  `:typed_command` (CLI/email) or `:button` (LiveView/Telegram/Discord/Slack);
  screenshot review is expressible as `:link` to the cache path.
- v0.49 vision/image-generation will add a richer image-resource class;
  v0.43 screenshots are intentionally inert content (bitmap + metadata),
  reused by v0.49 once that class lands.

## Non-Goals

- No arbitrary crawling, recursive link following, or sitemap traversal.
- No automatic memory promotion from browser content; manual promotion uses
  existing memory actions with the extracted text as input.
- No browser-owned confirmation path; confirmations remain Security Central +
  `AllbertAssist.Confirmations`.
- No unrestricted account operation, no login flows, no authenticated session
  reuse, no persistent browser profiles in v0.43.
- No JavaScript evaluation actions in v0.43 (`evaluate_js`, `add_init_script`,
  `expose_function`); JS runs as part of normal page rendering only.
- No WebSocket, service worker registration, push notifications, background
  sync, geolocation, microphone, camera, or clipboard access.
- No upload (multipart file POST) beyond what `:browser_form_fill` would
  enable, which is denied by default at v0.43.
- No headed mode in v0.43 unless decided otherwise in M1; headless is the
  default and the only audited path.
- No multi-tab, multi-window, or popup orchestration; one active page per
  session at v0.43.
- No Office, archive, or unknown-binary extraction (parked in
  `docs/plans/future-features.md`).

## Deferred

Tracked in `docs/plans/future-features.md`:

- "Broad Office, Archive, And Unknown-Binary Extraction" (existing entry).
- "Authenticated Browser Operation And Persistent Profiles" (new entry added
  during v0.43 deepening).
- Multi-tab/window orchestration, popup handling, BFCache-aware navigation.
- `evaluate_js`, network HAR capture, and other power-user browser primitives.
- Headed mode and operator-visible browser windows.
- Browser-driven captive-portal/SSO flows.
