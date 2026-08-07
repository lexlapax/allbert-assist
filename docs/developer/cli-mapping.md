# Mix Task → `allbert` Command Mapping

Generated from `AllbertAssist.CLI.Commands.task_dispositions/0` (the disposition
table the `cli-command-inventory-spine-map-001` eval row asserts). Operator
tasks re-front onto the unified `allbert` dispatcher; developer/CI tasks stay
Mix-only in a checkout.

**v1.4 M1.a3:** `mix allbert <argv>` is the source-checkout parity front door.
Its owner is `apps/allbert_composition/lib/mix/tasks/allbert.ex`; ordinary
commands invoke the same `AllbertAssist.Pack.ProductCLI.run_entry/1` boundary as
the packaged executable. ProductCLI classifies through the residual
`AllbertAssist.CLI` table, starts Req only for non-license paths, preserves
attach-first behavior, and enters embedded composition only after a proven
pre-dispatch transport failure. It deliberately loads configuration without
starting Allbert, so attach transport gets the first opportunity and a second
writer is not booted. `mix allbert tui` delegates to the existing thin TUI
launcher; `mix allbert serve` delegates to the Phoenix daemon launcher with the
writer-lock contract. The older `mix allbert.<area>` tasks remain developer and
compatibility entry points, but source feature validation uses the unified form:
`mix allbert ask`, `mix allbert search`, and `mix allbert admin ...` against the
same running source daemon and disposable Allbert Home.

**v0.62 M8.7:** every `allbert admin <area>` home below is **live in the packaged
binary** and owns its full subcommand set through a release-safe
`AllbertAssist.CLI.Areas.<Area>` module that is the single source of truth shared
with `mix allbert.<area>` (identical dispatch + output on both surfaces). Run
`allbert admin <area>` with no subcommand for its usage. `ask`/`chat`/`tui` are
real: `ask` runs a one-shot turn, `tui` is an attach-only terminal client of the
already-running daemon, and `chat` points at the web workspace. `allbert tui`
and `mix allbert.tui` own TTY/input/render only; neither may boot Repo, Runtime,
migrations, providers, or an embedded writer. A `commands_test` invariant
asserts every mapped home resolves in the operator table (no
advertised-but-missing command).

The packaged dispatcher scopes OTP `+Bc` to `allbert tui` so raw Ctrl-C reaches
the client's state-aware detach or active-turn interrupt/cancel path; it does
not change daemon signal handling. The source-checkout equivalent is
`ERL_AFLAGS="${ERL_AFLAGS:+$ERL_AFLAGS }+Bc" mix allbert tui`; the flag must be
present before the Mix VM starts. The focused
v1.2.5 PTY runner and documented operator command apply that posture only to
their TUI child.

The table maps legacy Mix task families to product command homes. v0.62 also
adds explicit subcommands that have no one-to-one legacy Mix task row:
`allbert admin model detect|install|pull`, `allbert admin service
status|install|uninstall`, `allbert admin health`, `allbert admin vault`, and
`allbert admin secrets migrate`. v1.2.5 adds the pre-runtime informational leaf
`allbert licenses`; its source twin generates or checks the reviewed catalog
union, while the packaged command only reads immutable artifact files.

Top-level packaged commands without a one-to-one Mix task still belong in this
inventory. This is the complete `CLI.Commands.groups/0` set:

| Packaged group | Disposition |
|---|---|
| `allbert ask` | Built-in runtime turn; source parity is `mix allbert ask` (legacy task: `mix allbert.ask`). |
| `allbert chat` | Built-in web workspace launcher; source parity is `mix allbert chat`. |
| `allbert tui` | Built-in thin daemon-attached terminal; source parity is `mix allbert tui` (legacy task: `mix allbert.tui`). |
| `allbert serve` | Built-in daemon/web runtime; source parity is `mix allbert serve`; legacy server tasks include `mix allbert.acp_server` and `mix allbert.mcp_server`. |
| `allbert search` | `CLI.Areas.Search` over the central conversation Search API; source parity is `mix allbert search`, with no legacy one-to-one task. |
| `allbert licenses` | Built-in pure packaged-evidence viewer; source parity is `mix allbert licenses`, while `mix allbert.licenses` owns catalog generation/checks. |
| `allbert onboard` | `CLI.Areas.Onboarding`; source parity is `mix allbert onboard` (legacy task: `mix allbert.onboard`). |
| `allbert admin` | Closed area/action/read table in `CLI.Commands.operator_table/0`; source parity is `mix allbert admin ...`. |

Search is intentionally top-level because it is a daily read surface, not an
administrative storage command. `allbert admin memory search` remains a
different operation over reviewed Memory claims. See the operator
[Conversation Search guide](../operator/conversation-search.md).

v1.3.1's `mix allbert.test qualify-head` remains development-only and has no
packaged `allbert` twin. It exercises the production DirectAnswer assembly from
a source checkout but records only offline, content-free qualification evidence;
it is not a runtime command or a new operator authority surface.

v1.3.2's `mix allbert.test preflight`, `scope --base`, `compatibility`, and
`release.v132` commands are likewise source-only developer/release tooling.
They validate repository state and select evidence; they grant no runtime
authority and have no packaged dispatcher twin.

| Mix task | `allbert` command |
|---|---|
| `mix allbert.acp_server` | `allbert serve` |
| `mix allbert.apps` | `allbert admin apps` |
| `mix allbert.ask` | `allbert ask` |
| `mix allbert.channels` | `allbert admin channels` |
| `mix allbert.confirmations` | `allbert admin confirmations` |
| `mix allbert.conversations` | `allbert admin threads` |
| `mix allbert.delegate` | `allbert admin objectives` |
| `mix allbert.dynamic` | `allbert admin plugins` |
| `mix allbert.ecto.migrate` | _mix-only (dev/CI)_ |
| `mix allbert.exec` | `allbert admin exec` |
| `mix allbert.external` | `allbert admin external` |
| `mix allbert.gen.app` | _mix-only (dev/CI)_ |
| `mix allbert.gen.flow` | _mix-only (dev/CI)_ |
| `mix allbert.gen.plugin` | _mix-only (dev/CI)_ |
| `mix allbert.gen.support` | _mix-only (dev/CI)_ |
| `mix allbert.gen.tool` | _mix-only (dev/CI)_ |
| `mix allbert.home.export` | `allbert admin home export` |
| `mix allbert.home.import` | `allbert admin home import` |
| `mix allbert.intent` | `allbert admin intent` |
| `mix allbert.jobs` | `allbert admin jobs` |
| `mix allbert.licenses` | `allbert licenses` |
| `mix allbert.marketplace` | `allbert admin marketplace` |
| `mix allbert.mcp` | `allbert admin mcp` |
| `mix allbert.mcp_server` | `allbert serve` |
| `mix allbert.memory` | `allbert admin memory` |
| `mix allbert.model` | `allbert admin models` |
| `mix allbert.objective` | `allbert admin objectives` |
| `mix allbert.objectives` | `allbert admin objectives` |
| `mix allbert.onboard` | `allbert onboard` |
| `mix allbert.packages` | `allbert admin packages` |
| `mix allbert.plan` | `allbert admin plan` |
| `mix allbert.plugins` | `allbert admin plugins` |
| `mix allbert.public_protocol` | `allbert admin public_protocol` |
| `mix allbert.resources` | `allbert admin resources` |
| `mix allbert.sandbox` | _mix-only (dev/CI)_ |
| `mix allbert.security` | `allbert admin trust` |
| `mix allbert.self_improvement` | `allbert admin self-improvement` |
| `mix allbert.sessions` | `allbert admin sessions` |
| `mix allbert.settings` | `allbert admin settings` |
| `mix allbert.skills` | `allbert admin skills` |
| `mix allbert.test` | _mix-only (dev/CI)_ |
| `mix allbert.test.raw` | _mix-only (dev/CI)_ |
| `mix allbert.threads` | `allbert admin threads` |
| `mix allbert.tools` | `allbert admin tools` |
| `mix allbert.tui` | `allbert tui` |
| `mix allbert.validate_app` | _mix-only (dev/CI)_ |
| `mix allbert.voice.local` | `allbert admin voice` |
| `mix allbert.workflows` | `allbert admin workflows` |
| `mix allbert.workspace` | `allbert admin workspace` |

## v1.8 Planned Profiling Area

v1.8 adds one source/package parity home after its registered actions exist:

| Source checkout | Packaged command | Contract |
|---|---|---|
| `mix allbert.profiling status` | `allbert admin profiling status` | Redacted feature, capture, distill, retention, and health state. |
| `mix allbert.profiling distill` | `allbert admin profiling distill` | Explicit deterministic local distillation; no model or network call. |
| `mix allbert.profiling suggestions` | `allbert admin profiling suggestions` | List and inspect user-owned profiling cards. |
| `mix allbert.profiling apply <id>` | `allbert admin profiling apply <id>` | Start or resume the confirmation-bound allowlisted compare-and-set path. |
| `mix allbert.profiling dismiss <id>` | `allbert admin profiling dismiss <id>` | Mark the named open card dismissed. |
| `mix allbert.profiling revert <id>` | `allbert admin profiling revert <id>` | Start or resume the separately confirmed exact-value revert path. |
| `mix allbert.profiling clear` | `allbert admin profiling clear` | Confirmed removal of usage events and profiling derivatives while preserving Settings and accountability records. |
| `mix allbert.profiling notify-enroll <channel> <target-ref>` | `allbert admin profiling notify-enroll <channel> <target-ref>` | Identity-reverified enrollment of one exact suggestion-notification target. |
| `mix allbert.profiling notify-unenroll <channel> <target-ref>` | `allbert admin profiling notify-unenroll <channel> <target-ref>` | Remove the exact suggestion-notification enrollment. |

The area is not advertised in `CLI.Commands.operator_table/0` before v1.8 ships.
Both fronts call the same `CLI.Areas.Profiling` dispatcher and registered action
set; neither surface writes Settings or profiling storage directly. `status`
remains available while profiling is paused so an operator can inspect health,
retention, and the clear path.
