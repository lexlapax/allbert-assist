# Channel Approval Primitives

Status: implemented in v0.52. ADR 0016 owns the channel boundary and the
approval primitive contract; ADR 0056 owns inbound clicker trust. This document
is the implementation guide for adapter authors.

## Contract

Every channel descriptor must declare:

```elixir
%{
  primitives: [:button, :typed_command, :list],
  threading: :native_threads
}
```

`AllbertAssist.Plugin.Validator` rejects missing, empty, or invalid
`primitives:` declarations. The allowed primitive atoms are:

- `:button`
- `:typed_command`
- `:link`
- `:list`

`AllbertAssist.Approval.Handoff.render/2` consumes an already-effective channel
descriptor and returns `{:ok, {primitive, payload}}` or `{:error, reason}`. It
chooses the highest-fidelity available primitive in this order:

```elixir
[:button, :typed_command, :link, :list]
```

`:link` is eligible only when the handoff payload includes a workspace URL.
Renderers remain responsible for translating the selected payload into provider
wire shape.

## Shipped Adapter Declarations

| Channel | Primitives | Notes |
|---|---|---|
| Discord | `[:button, :typed_command, :list]` | Buttons render to Discord components; typed command fallback parses exact `ALLBERT:<ACTION>:<id>`. |
| Slack | `[:button, :typed_command, :list]` | Buttons render to Slack Block Kit; typed command fallback parses exact `ALLBERT:<ACTION>:<id>`. |
| Telegram | `[:button, :typed_command, :list]` | Retrofits the v0.16 inline-button behavior through the shared selector. |
| Email | `[:typed_command, :list]` | Typed command is the highest-fidelity email primitive. |
| CLI | `[:typed_command, :list]` | Local rich surfaces remain runtime-owned, not channel plugins. |
| Web | `[:button, :typed_command, :list]` | LiveView renders and dispatches only; it does not own approval policy. |

Provider settings may remove a primitive before rendering. For example,
`channels.discord.render_approval_buttons=false` and
`channels.slack.render_approval_buttons=false` force the renderer to use the
typed-command fallback.

## Callback Shape

Button callback ids use the shared shape:

```text
allbert:v1:<action>:<confirmation_id>
```

Typed command fallbacks use:

```text
ALLBERT:<ACTION>:<confirmation_id>
```

The parser must be exact. Free text that merely contains a callback-looking
fragment is ignored. Supported actions are `approve`, `deny`, and `show`.

## Authority Rules

- The renderer never grants authority. It only formats a pending confirmation.
- A provider callback re-resolves the clicker on every interaction.
- The callback channel must match the pending confirmation origin; a Slack
  callback cannot resolve a Discord-origin confirmation and vice versa.
- Unmapped or non-allowlisted clickers reject before
  `Confirmations.resolve/4`.
- Provider callback ids, Slack `action_id` values, and Discord `custom_id`
  values are not permission tokens.

## Tests

Use the focused contract tests when changing primitives or renderers:

```sh
MIX_ENV=test mix test \
  apps/allbert_assist/test/allbert_assist/approval/handoff_test.exs \
  apps/allbert_assist/test/allbert_assist/plugin/validator_test.exs \
  apps/allbert_assist/test/allbert_assist/channels/discord_test.exs \
  apps/allbert_assist/test/allbert_assist/channels/slack_test.exs \
  apps/allbert_assist/test/security/v052_channel_pack_eval_test.exs
```

The release handoff gate is:

```sh
mix allbert.test release.v052
```
