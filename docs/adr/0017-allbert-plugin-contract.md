# ADR 0017: Allbert Plugin Contract

## Status

Proposed.

## Context

Allbert now has several extension-shaped mechanisms, but they are not yet one
extension system:

- `AllbertAssist.App` lets workspace apps register app identity, actions,
  skill paths, child supervision, and navigation metadata.
- `AllbertAssist.Channels` has a provider-neutral event, identity, session,
  and rendering substrate, but Telegram and email are still wired directly into
  the channel supervisor and settings schema.
- `AllbertAssist.Skills.Registry` can discover skill directories from built-in,
  project, app, user, configured, and imported roots.
- `AllbertAssist.Actions.Registry` is still mostly static, with app metadata
  stamped after app registration.

The next planned domain app, StockSage, should not become another special case.
The broader product direction is a developer-extensible framework where a
developer can contribute a channel adapter, a complete workspace app, a skill
pack, a small set of actions, or a combination of those pieces. App
registration is one contribution type inside that broader plugin model, not
the plugin model itself.

At the same time, Allbert's existing safety posture is clear: runtime-facing
behavior belongs behind signals, registered Jido actions, Security Central,
Settings Central, confirmations, traces, and audits. Loading arbitrary code
from user-owned folders at startup would violate the non-goals in ADR 0003,
ADR 0007, ADR 0010, ADR 0015, and ADR 0016.

## Decision

Allbert will add a plugin contract centered on `AllbertAssist.Plugin` and
`AllbertAssist.Plugin.Registry`.

A plugin is the packaging and discovery boundary for contributions. It may
contribute any combination of:

- apps, implemented through `AllbertAssist.App`
- channels, implemented through the channel adapter contract
- registered Jido actions
- skill roots containing `SKILL.md` files
- Settings Central schema entries
- supervised children
- diagnostics and metadata

A plugin does not grant authority. Plugin registration does not imply trust,
permission, skill enablement, resource grants, confirmation bypass, route
mounting, external publishing, or app-scoped authorization. Runtime-facing
effects still execute through the existing action/runtime/security boundaries.

Plugin ids are strings, not atoms. Operator or manifest input must never create
atoms. Any atom-bearing callback belongs to compiled, trusted Elixir modules
that are already part of the running code path.

Allbert will have three plugin source classes:

- **Shipped source-tree plugins**: plugin folders under `<project_root>/plugins`
  that are reviewed with the project and compiled into `allbert_assist` by
  explicit build configuration.
- **Project plugins**: source-tree plugins under `./plugins` that are reviewed
  and compiled as part of the project/release by developer action.
- **Home plugins**: folders under `<ALLBERT_HOME>/plugins` that may contribute
  manifests and skill roots in v0.17, but do not compile or load arbitrary
  Elixir modules at runtime.

The default plugin scan paths are:

- `<project_root>/plugins`
- `<ALLBERT_HOME>/plugins`

Settings Central owns user-facing plugin configuration through keys such as
`plugins.enabled`, `plugins.disabled`, `plugins.scan_paths`,
`plugins.trusted_project_roots`, and `plugins.load_policy`. Deployment/test
configuration may override plugin roots for deterministic boot tests, but
runtime preferences remain settings-backed.

`AllbertAssist.Plugin.Registry` is the single contribution index for v0.17.
Channel descriptors are first-class plugin registry entries; v0.17 does not
introduce a separate channel registry. The shared `AllbertAssist.Channels`
context and `AllbertAssist.Channels.Supervisor` consume channel descriptors
from the plugin registry for channel summaries, settings lookup, credential
status, session derivation, and adapter child specs.

Plugin entries are normalized records, not raw manifests. Each entry carries a
string plugin id, display name, version, kind, source, status, trust status,
compiled module when present, root/manifest paths, bounded contribution lists,
and diagnostics. CLI and registered actions render summaries from normalized
entries and must not print raw unbounded manifests or secrets.

v0.17 converts Telegram and email into shipped source-tree channel plugins
under `./plugins/allbert.telegram` and `./plugins/allbert.email`. Their
adapter/client/parser/renderer implementation modules keep the existing
`AllbertAssist.Channels.Telegram.*` and `AllbertAssist.Channels.Email.*`
module names, but the files move into the plugin folders. Registration
ownership moves to `AllbertAssist.Plugins.Telegram` and
`AllbertAssist.Plugins.Email`. The channel supervisor and channel summary code
must consume registered channel contributions instead of hardcoding Telegram
and email.

The stable v0.16 Settings Central keys for Telegram and email remain stable:
`channels.telegram.*` and `channels.email.*`. For bootstrap safety, their
schema remains statically known in core during v0.17 while the shipped plugin
modules expose matching settings metadata for plugin inspection, channel
summaries, and future plugin schema merging.

Runtime discovery may read plugin manifests, but manifests are not dynamic code
loading instructions. A module named in a manifest can be registered only when
it is already compiled and the plugin id/module pair is present in a shipped or
explicitly configured allowlist. Home-plugin manifests that name modules do not
cause compilation, code loading, atom creation, or registration in v0.17.

Allbert will add a plugin child supervisor. Compiled plugin modules may return
a child spec from `child_spec/1`; bootstrap starts those child specs under
`AllbertAssist.Plugin.ChildSupervisor`. `:ignore` remains the normal value for
metadata-only plugins. Channel adapters remain under
`AllbertAssist.Channels.Supervisor` because they are channel descriptors, not
general plugin children.

Plugin-contributed OTP processes must live under the child spec returned by the
plugin entrypoint. Domain apps may use their own supervisor, such as
`StockSage.Supervisor`, but bridge processes, native workers, and background
queues for that app should be descendants of that supervisor so they share the
plugin lifecycle and cannot bypass plugin enablement/disablement semantics.

StockSage should then land as a plugin-contributed app in v0.20 through
`./plugins/stocksage`. The app contract remains intact; the plugin layer feeds
`StockSage.App` into `AllbertAssist.App.Registry` rather than replacing the
app registry. ADR 0018 owns StockSage's local domain and persistence boundary.

## Consequences

- Allbert gains one extension entrypoint instead of separate one-off wiring for
  apps, channels, actions, settings schema, and skill roots.
- StockSage can prove the same mechanism that third-party developers will use.
- Telegram and email become proving examples of shipped source-tree channel
  plugins.
- Channel discovery becomes data-driven through plugin descriptors without
  adding a second channel registry.
- Existing Telegram/email settings survive the file move without a settings
  migration.
- Skill-only home plugins are possible without introducing runtime code
  loading.
- Code-bearing third-party plugins require developer review, explicit
  compilation, and tests before they can participate in runtime behavior.
- v0.18 app/surface work can build on the plugin layer instead of broadening
  app registration into a catch-all extension registry.
- v0.29 generator work should generate plugin scaffolds, not only app modules.

## Deferred

- Runtime compilation or loading of arbitrary `.ex`, `.beam`, NIF, script, or
  dependency code from `<ALLBERT_HOME>/plugins`.
- Automatic compilation of arbitrary `./plugins/*/lib` directories without a
  reviewed project/release change.
- Remote plugin marketplace install/update.
- Dependency resolution or package-manager execution during plugin discovery.
- Plugin hot reload for code-bearing plugins.
- Sandboxed untrusted plugin execution.
- Hosted multi-user plugin administration and role-based enablement.
- Automatic trust, skill enablement, action permission grants, or resource
  grants from plugin manifests.
