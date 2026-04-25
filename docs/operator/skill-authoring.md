# Skill authoring operator guide

v0.12 ships `skill-author`, a first-party skill that helps create AgentSkills-format skills through conversation. The user describes the capability; Allbert drafts the skill; the standard install quarantine remains the trust gate.

## When To Use It

Ask naturally:

```text
make me a skill that summarizes project notes
create a skill that checks release docs
build a skill for triaging support emails
```

Intent routing can activate `skill-author` from those patterns. You can inspect the shipped skill like any other skill:

```bash
cargo run -p allbert-cli -- skills show skill-author
```

## Draft Flow

The authoring flow collects:

- skill name
- description
- capability summary
- preferred interpreter, if scripts are needed
- required tools
- final confirmation to submit the draft

Drafts are written through the kernel `create_skill` tool with `skip_quarantine = false`. That means they land in:

```text
~/.allbert/skills/incoming/<draft-name>/
```

Incoming drafts persist across turns and sessions. Final submission still uses the normal skill install preview and confirmation flow.

## Provenance

Skills now carry optional provenance frontmatter:

```yaml
provenance: external | local-path | git | self-authored
```

Existing skills without the field load as `external`. Drafts produced by `skill-author` carry `self-authored`, and that value survives promotion from `incoming/` to `installed/`.

Show installed provenance:

```bash
cargo run -p allbert-cli -- skills list
cargo run -p allbert-cli -- skills show <name>
```

The `Source` column is observability, not a policy bypass. Self-authored skills are reviewed like any external install.

## Interpreter Guidance

If you do not specify an interpreter, `skill-author` recommends Python because fresh profiles already allow `python` in `security.exec_allow`.

Lua is available only when both gates are enabled:

```toml
[scripting]
engine = "lua"

[security]
exec_allow = ["bash", "python", "lua"]
```

If a draft declares a Lua script while the embedded engine is disabled, install preview refuses it with a clear message.

## CLI Escape Hatch

The v0.4 wizard remains available for technical users who want to scaffold by command:

```bash
cargo run -p allbert-cli -- skills init <name>
```

That path is explicit and local. The natural-language `skill-author` flow is the default operator experience.

## Related Docs

- [Self-improvement guide](self-improvement.md)
- [Scripting guide](scripting.md)
- [v0.12 upgrade notes](../notes/v0.12-upgrade-2026-04-25.md)
