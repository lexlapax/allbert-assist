# Mix task -> `allbert` command mapping (v0.62 M3)

Generated from `AllbertAssist.CLI.Commands.task_dispositions/0` (the disposition
table the `cli-command-inventory-spine-map-001` eval row asserts). Operator
tasks re-front onto the unified `allbert` dispatcher; developer/CI tasks stay
Mix-only in a checkout.

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
| `mix allbert.marketplace` | `allbert admin apps` |
| `mix allbert.mcp` | `allbert admin mcp` |
| `mix allbert.mcp_server` | `allbert serve` |
| `mix allbert.memory` | `allbert admin memory` |
| `mix allbert.model` | `allbert admin models` |
| `mix allbert.objective` | `allbert admin objectives` |
| `mix allbert.objectives` | `allbert admin objectives` |
| `mix allbert.onboard` | `allbert admin onboarding` |
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
