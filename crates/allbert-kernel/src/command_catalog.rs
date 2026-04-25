use std::collections::BTreeSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum CommandGroup {
    Conversation,
    Status,
    Review,
    Memory,
    Skills,
    SelfImprovement,
    Settings,
    System,
}

impl CommandGroup {
    pub const ALL: [Self; 8] = [
        Self::Conversation,
        Self::Status,
        Self::Review,
        Self::Memory,
        Self::Skills,
        Self::SelfImprovement,
        Self::Settings,
        Self::System,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::Conversation => "conversation",
            Self::Status => "status",
            Self::Review => "review",
            Self::Memory => "memory",
            Self::Skills => "skills",
            Self::SelfImprovement => "self_improvement",
            Self::Settings => "settings",
            Self::System => "system",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Conversation => "Conversation",
            Self::Status => "Status",
            Self::Review => "Review",
            Self::Memory => "Memory",
            Self::Skills => "Skills",
            Self::SelfImprovement => "Self-improvement",
            Self::Settings => "Settings",
            Self::System => "System",
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            Self::Conversation => "Start, continue, and understand interactive use.",
            Self::Status => "Inspect daemon, runtime, and resource posture.",
            Self::Review => "Resolve approvals and review pending artifacts.",
            Self::Memory => "Inspect and manage memory routing, staging, facts, and episodes.",
            Self::Skills => "Inspect installed, incoming, and self-authored skills.",
            Self::SelfImprovement => {
                "Review patch approvals, self-improvement configuration, install, and cleanup."
            }
            Self::Settings => "Inspect and change supported profile settings.",
            Self::System => "Diagnose setup, profile paths, daemon state, and local identity.",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum CommandSurface {
    Cli,
    Tui,
    Repl,
    Telegram,
}

impl CommandSurface {
    pub fn label(self) -> &'static str {
        match self {
            Self::Cli => "cli",
            Self::Tui => "tui",
            Self::Repl => "repl",
            Self::Telegram => "telegram",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CommandGroupDescriptor {
    pub group: CommandGroup,
    pub label: &'static str,
    pub description: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CommandDescriptor {
    pub id: &'static str,
    pub display: &'static str,
    pub group: CommandGroup,
    pub surfaces: &'static [CommandSurface],
    pub summary: &'static str,
}

const CLI: &[CommandSurface] = &[CommandSurface::Cli];
const TUI: &[CommandSurface] = &[CommandSurface::Tui];
const REPL: &[CommandSurface] = &[CommandSurface::Repl];
const TELEGRAM: &[CommandSurface] = &[CommandSurface::Telegram];
const CLI_TUI: &[CommandSurface] = &[CommandSurface::Cli, CommandSurface::Tui];
const CLI_TUI_REPL: &[CommandSurface] = &[
    CommandSurface::Cli,
    CommandSurface::Tui,
    CommandSurface::Repl,
];
const ALL_INTERACTIVE: &[CommandSurface] = &[
    CommandSurface::Cli,
    CommandSurface::Tui,
    CommandSurface::Repl,
    CommandSurface::Telegram,
];

pub fn command_groups() -> Vec<CommandGroupDescriptor> {
    CommandGroup::ALL
        .iter()
        .copied()
        .map(|group| CommandGroupDescriptor {
            group,
            label: group.label(),
            description: group.description(),
        })
        .collect()
}

pub fn command_catalog() -> Vec<CommandDescriptor> {
    vec![
        command(
            "cli:repl",
            "allbert-cli repl",
            CommandGroup::Conversation,
            CLI,
            "Start or attach the interactive REPL/TUI.",
        ),
        command(
            "repl:/help",
            "/help",
            CommandGroup::Conversation,
            REPL,
            "Show interactive help.",
        ),
        command(
            "tui:/help",
            "/help",
            CommandGroup::Conversation,
            TUI,
            "Show grouped TUI help.",
        ),
        command(
            "tui:/quit",
            "/quit",
            CommandGroup::Conversation,
            TUI,
            "Exit the TUI.",
        ),
        command(
            "tui:/clear",
            "/clear",
            CommandGroup::Conversation,
            TUI,
            "Clear local transcript display where supported.",
        ),
        command(
            "cli:telemetry",
            "allbert-cli telemetry",
            CommandGroup::Status,
            CLI,
            "Show daemon-owned session telemetry.",
        ),
        command(
            "cli:activity",
            "allbert-cli activity",
            CommandGroup::Status,
            CLI,
            "Show current daemon-owned activity.",
        ),
        command(
            "cli:daemon-status",
            "allbert-cli daemon status",
            CommandGroup::Status,
            CLI,
            "Show daemon status.",
        ),
        command(
            "cli:daemon-channels",
            "allbert-cli daemon channels",
            CommandGroup::Status,
            CLI,
            "Inspect daemon channel posture.",
        ),
        command(
            "tui:/status",
            "/status",
            CommandGroup::Status,
            TUI,
            "Show compact runtime status.",
        ),
        command(
            "tui:/activity",
            "/activity",
            CommandGroup::Status,
            TUI,
            "Show current daemon-owned activity.",
        ),
        command(
            "tui:/telemetry",
            "/telemetry",
            CommandGroup::Status,
            TUI,
            "Show session telemetry.",
        ),
        command(
            "tui:/context",
            "/context",
            CommandGroup::Status,
            TUI,
            "Show context-window and prompt composition state.",
        ),
        command(
            "tui:/agents",
            "/agents",
            CommandGroup::Status,
            TUI,
            "Show generated agent routing summary.",
        ),
        command(
            "telegram:/activity",
            "/activity",
            CommandGroup::Status,
            TELEGRAM,
            "Show compact activity in Telegram.",
        ),
        command(
            "telegram:/status",
            "/status",
            CommandGroup::Status,
            TELEGRAM,
            "Show compact Telegram status.",
        ),
        command(
            "cli:inbox",
            "allbert-cli inbox",
            CommandGroup::Review,
            CLI,
            "List, show, accept, or reject inbox approvals.",
        ),
        command(
            "cli:approvals",
            "allbert-cli approvals",
            CommandGroup::Review,
            CLI,
            "Inspect approval records.",
        ),
        command(
            "tui:/inbox",
            "/inbox",
            CommandGroup::Review,
            TUI,
            "Resolve approvals from the TUI.",
        ),
        command(
            "telegram:/approve",
            "/approve",
            CommandGroup::Review,
            TELEGRAM,
            "Accept a pending Telegram approval.",
        ),
        command(
            "telegram:/reject",
            "/reject",
            CommandGroup::Review,
            TELEGRAM,
            "Reject a pending Telegram approval.",
        ),
        command(
            "cli:memory",
            "allbert-cli memory",
            CommandGroup::Memory,
            CLI,
            "Inspect, stage, forget, restore, and manage curated memory.",
        ),
        command(
            "tui:/memory",
            "/memory",
            CommandGroup::Memory,
            TUI,
            "Inspect memory state and staged entries.",
        ),
        command(
            "cli:skills",
            "allbert-cli skills",
            CommandGroup::Skills,
            CLI,
            "Inspect, validate, install, update, disable, enable, and remove skills.",
        ),
        command(
            "tui:/skills",
            "/skills",
            CommandGroup::Skills,
            TUI,
            "Inspect installed and incoming skills.",
        ),
        command(
            "cli:self-improvement",
            "allbert-cli self-improvement",
            CommandGroup::SelfImprovement,
            CLI,
            "Review and install self-improvement artifacts.",
        ),
        command(
            "tui:/self-improvement",
            "/self-improvement",
            CommandGroup::SelfImprovement,
            TUI,
            "Review self-improvement config, diffs, installs, and cleanup.",
        ),
        command(
            "cli:settings",
            "allbert-cli settings",
            CommandGroup::Settings,
            CLI,
            "Inspect and change supported settings.",
        ),
        command(
            "tui:/settings",
            "/settings",
            CommandGroup::Settings,
            TUI,
            "Inspect and change supported settings.",
        ),
        command(
            "cli:daemon",
            "allbert-cli daemon",
            CommandGroup::System,
            CLI,
            "Start, stop, restart, and inspect daemon logs.",
        ),
        command(
            "cli:config",
            "allbert-cli config",
            CommandGroup::System,
            CLI,
            "Restore config.toml from the daemon last-good snapshot.",
        ),
        command(
            "cli:profile",
            "allbert-cli profile",
            CommandGroup::System,
            CLI,
            "Export or import profile continuity state.",
        ),
        command(
            "cli:identity",
            "allbert-cli identity",
            CommandGroup::System,
            CLI,
            "Inspect and update local identity bindings.",
        ),
        command(
            "cli:sessions",
            "allbert-cli sessions",
            CommandGroup::System,
            CLI,
            "List, show, resume, or forget sessions.",
        ),
        command(
            "cli:heartbeat",
            "allbert-cli heartbeat",
            CommandGroup::System,
            CLI,
            "Inspect or edit heartbeat posture.",
        ),
        command(
            "cli:jobs",
            "allbert-cli jobs",
            CommandGroup::System,
            CLI,
            "List, run, and manage jobs.",
        ),
        command(
            "cli:learning",
            "allbert-cli learning",
            CommandGroup::System,
            CLI,
            "Preview or run learning jobs.",
        ),
        command(
            "cli:agents",
            "allbert-cli agents",
            CommandGroup::Status,
            CLI,
            "List contributed agents.",
        ),
        command(
            "tui:/doctor",
            "/doctor",
            CommandGroup::System,
            TUI,
            "Diagnose setup and daemon posture.",
        ),
        command(
            "tui:/logs",
            "/logs",
            CommandGroup::System,
            TUI,
            "Show recent daemon logs where implemented.",
        ),
        command(
            "repl:/status",
            "/status",
            CommandGroup::Status,
            REPL,
            "Show REPL runtime status.",
        ),
        command(
            "repl:/telemetry",
            "/telemetry",
            CommandGroup::Status,
            REPL,
            "Show REPL telemetry.",
        ),
        command(
            "repl:/memory",
            "/memory",
            CommandGroup::Memory,
            REPL,
            "Inspect memory from classic REPL.",
        ),
        command(
            "repl:/cost",
            "/cost",
            CommandGroup::Status,
            REPL,
            "Show or override cost state.",
        ),
        command(
            "repl:/model",
            "/model",
            CommandGroup::System,
            REPL,
            "Inspect or update model selection.",
        ),
        command(
            "repl:/setup",
            "/setup",
            CommandGroup::System,
            REPL,
            "Rerun guided setup.",
        ),
        command(
            "repl:/statusline",
            "/statusline",
            CommandGroup::Settings,
            REPL,
            "Toggle TUI status-line settings from classic REPL.",
        ),
        command(
            "telegram:/reset",
            "/reset",
            CommandGroup::Conversation,
            TELEGRAM,
            "Reset Telegram conversation routing.",
        ),
        command(
            "telegram:/override",
            "/override",
            CommandGroup::Review,
            TELEGRAM,
            "Approve a one-turn cost-cap override.",
        ),
        command(
            "surface:shared-status",
            "status surfaces",
            CommandGroup::Status,
            ALL_INTERACTIVE,
            "Shared status rendering family.",
        ),
        command(
            "surface:shared-settings",
            "settings surfaces",
            CommandGroup::Settings,
            CLI_TUI_REPL,
            "Shared settings rendering family.",
        ),
        command(
            "surface:shared-review",
            "review surfaces",
            CommandGroup::Review,
            CLI_TUI,
            "Shared review rendering family.",
        ),
    ]
}

pub fn command_catalog_errors(catalog: &[CommandDescriptor]) -> Vec<String> {
    let documented_groups = CommandGroup::ALL.into_iter().collect::<BTreeSet<_>>();
    let mut seen = BTreeSet::new();
    let mut errors = Vec::new();

    for descriptor in catalog {
        if descriptor.id.trim().is_empty() {
            errors.push("command descriptor has an empty id".into());
        }
        if descriptor.display.trim().is_empty() {
            errors.push(format!("{} has an empty display string", descriptor.id));
        }
        if descriptor.summary.trim().is_empty() {
            errors.push(format!("{} has an empty summary", descriptor.id));
        }
        if descriptor.surfaces.is_empty() {
            errors.push(format!("{} has no surfaces", descriptor.id));
        }
        if !documented_groups.contains(&descriptor.group) {
            errors.push(format!("{} uses undocumented group", descriptor.id));
        }
        if !seen.insert(descriptor.id) {
            errors.push(format!(
                "{} is assigned to more than one command group",
                descriptor.id
            ));
        }
    }

    for group in CommandGroup::ALL {
        if !catalog.iter().any(|descriptor| descriptor.group == group) {
            errors.push(format!("group {} has no commands", group.id()));
        }
    }

    errors
}

const fn command(
    id: &'static str,
    display: &'static str,
    group: CommandGroup,
    surfaces: &'static [CommandSurface],
    summary: &'static str,
) -> CommandDescriptor {
    CommandDescriptor {
        id,
        display,
        group,
        surfaces,
        summary,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_catalog_assigns_every_entry_to_one_group() {
        let catalog = command_catalog();
        let errors = command_catalog_errors(&catalog);
        assert!(errors.is_empty(), "{}", errors.join("\n"));
    }

    #[test]
    fn command_groups_are_documented() {
        let groups = command_groups();
        assert_eq!(groups.len(), CommandGroup::ALL.len());
        for group in groups {
            assert!(!group.label.is_empty());
            assert!(!group.description.is_empty());
        }
    }

    #[test]
    fn command_catalog_covers_public_settings_and_review_surfaces() {
        let catalog = command_catalog();
        assert!(
            catalog
                .iter()
                .any(|command| command.id == "cli:settings"
                    && command.group == CommandGroup::Settings)
        );
        assert!(catalog
            .iter()
            .any(|command| command.id == "tui:/inbox" && command.group == CommandGroup::Review));
    }
}
