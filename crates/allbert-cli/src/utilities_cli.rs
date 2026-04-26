use std::path::PathBuf;

use allbert_kernel::{
    disable_utility, discover_utilities, enable_utility, inspect_utility, list_enabled_utilities,
    utility_doctor, AllbertPaths, Config, EnabledUtilityEntry, LocalUtilityDiscovery,
    UtilityDoctorReport, UtilityEnableResult,
};
use anyhow::{bail, Result};
use clap::Subcommand;

#[derive(Subcommand, Debug)]
#[command(
    after_long_help = "EXAMPLES:\n  allbert-cli utilities discover --offline\n  allbert-cli utilities list --offline\n  allbert-cli utilities show rg --offline\n  allbert-cli utilities enable rg\n  allbert-cli utilities disable rg\n  allbert-cli utilities doctor\n"
)]
pub enum UtilitiesCommand {
    /// Discover first-party catalog utilities on PATH.
    Discover {
        #[arg(long)]
        offline: bool,
        #[arg(long)]
        json: bool,
    },
    /// List operator-enabled utilities.
    List {
        #[arg(long)]
        offline: bool,
        #[arg(long)]
        json: bool,
    },
    /// Show one catalog utility and any enabled manifest entry.
    Show {
        utility_id: String,
        #[arg(long)]
        offline: bool,
        #[arg(long)]
        json: bool,
    },
    /// Enable one catalog utility by id.
    Enable {
        utility_id: String,
        #[arg(long)]
        path: Option<PathBuf>,
    },
    /// Disable one enabled utility.
    Disable { utility_id: String },
    /// Refresh enabled utility drift status.
    Doctor {
        #[arg(long)]
        json: bool,
    },
}

pub fn run(paths: &AllbertPaths, config: &Config, command: UtilitiesCommand) -> Result<()> {
    match command {
        UtilitiesCommand::Discover { offline, json } => {
            println!("{}", discover(paths, offline, json)?);
        }
        UtilitiesCommand::List { offline, json } => {
            println!("{}", list(paths, offline, json)?);
        }
        UtilitiesCommand::Show {
            utility_id,
            offline,
            json,
        } => {
            println!("{}", show(paths, &utility_id, offline, json)?);
        }
        UtilitiesCommand::Enable { utility_id, path } => {
            ensure_enabled(config)?;
            let result = enable_utility(paths, &config.security, &utility_id, path.as_deref())?;
            println!("{}", render_enable(&result));
        }
        UtilitiesCommand::Disable { utility_id } => {
            ensure_enabled(config)?;
            let removed = disable_utility(paths, &utility_id)?;
            println!(
                "{}",
                if removed {
                    format!("disabled utility {utility_id}")
                } else {
                    format!("utility {utility_id} was not enabled")
                }
            );
        }
        UtilitiesCommand::Doctor { json } => {
            ensure_enabled(config)?;
            let report = utility_doctor(paths, &config.security)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!("{}", render_doctor(&report));
            }
        }
    }
    Ok(())
}

pub fn discover(paths: &AllbertPaths, offline: bool, json: bool) -> Result<String> {
    let entries = discover_utilities(paths)?;
    if json {
        return Ok(serde_json::to_string_pretty(&entries)?);
    }
    let mut rendered = render_discovery(&entries);
    if offline {
        rendered = format!("offline utility discovery\n{rendered}");
    }
    Ok(rendered)
}

pub fn list(paths: &AllbertPaths, offline: bool, json: bool) -> Result<String> {
    let entries = list_enabled_utilities(paths)?;
    if json {
        return Ok(serde_json::to_string_pretty(&entries)?);
    }
    let mut rendered = render_enabled(&entries);
    if offline {
        rendered = format!("offline enabled utilities\n{rendered}");
    }
    Ok(rendered)
}

pub fn show(paths: &AllbertPaths, id: &str, offline: bool, json: bool) -> Result<String> {
    let (discovery, enabled) = inspect_utility(paths, id)?;
    if json {
        return Ok(serde_json::to_string_pretty(&(discovery, enabled))?);
    }
    let mut rendered = render_show(&discovery, enabled.as_ref());
    if offline {
        rendered = format!("offline utility detail\n{rendered}");
    }
    Ok(rendered)
}

fn ensure_enabled(config: &Config) -> Result<()> {
    if !config.local_utilities.enabled {
        bail!("local_utilities.enabled is false; enable it before mutating utilities");
    }
    Ok(())
}

fn render_discovery(entries: &[LocalUtilityDiscovery]) -> String {
    if entries.is_empty() {
        return "no catalog utilities".into();
    }
    let mut lines = vec!["utility catalog:".to_string()];
    for entry in entries {
        lines.push(format!(
            "- {} installed={} enabled={} path={}",
            entry.id,
            yes_no(entry.installed_path.is_some()),
            yes_no(entry.enabled),
            entry.installed_path.as_deref().unwrap_or("(not found)")
        ));
    }
    lines.join("\n")
}

fn render_enabled(entries: &[EnabledUtilityEntry]) -> String {
    if entries.is_empty() {
        return "no enabled utilities".into();
    }
    let mut lines = vec!["enabled utilities:".to_string()];
    for entry in entries {
        lines.push(format!(
            "- {} status={} path={} verified={}",
            entry.id,
            entry.status.label(),
            entry.path_canonical,
            entry.verified_at
        ));
    }
    lines.join("\n")
}

fn render_show(discovery: &LocalUtilityDiscovery, enabled: Option<&EnabledUtilityEntry>) -> String {
    let mut lines = vec![
        format!("utility:     {}", discovery.id),
        format!("name:        {}", discovery.name),
        format!("description: {}", discovery.description),
        format!(
            "candidates:  {}",
            discovery.executable_candidates.join(", ")
        ),
        format!(
            "installed:   {}",
            discovery.installed_path.as_deref().unwrap_or("(not found)")
        ),
    ];
    if let Some(enabled) = enabled {
        lines.push(format!("enabled:     yes ({})", enabled.status.label()));
        lines.push(format!("path:        {}", enabled.path_canonical));
        lines.push(format!("version:     {}", fallback(&enabled.version)));
    } else {
        lines.push("enabled:     no".into());
    }
    lines.join("\n")
}

fn render_enable(result: &UtilityEnableResult) -> String {
    format!(
        "enabled utility {}\npath:      {}\nstatus:    {}\nexec:      {}",
        result.entry.id,
        result.entry.path_canonical,
        result.entry.status.label(),
        result.exec_policy.note
    )
}

fn render_doctor(report: &UtilityDoctorReport) -> String {
    let mut lines = vec![format!(
        "utilities doctor\nmanifest: {}",
        report.manifest_path
    )];
    if report.entries.is_empty() {
        lines.push("enabled utilities: none".into());
    } else {
        for entry in &report.entries {
            lines.push(format!(
                "- {} status={} path={}",
                entry.id,
                entry.status.label(),
                entry.path_canonical
            ));
        }
    }
    lines.join("\n")
}

fn fallback(value: &str) -> &str {
    if value.trim().is_empty() {
        "(unknown)"
    } else {
        value
    }
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use allbert_kernel::AllbertPaths;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    fn temp_paths(name: &str) -> AllbertPaths {
        let unique = format!(
            "allbert-utilities-cli-{name}-{}-{}",
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default()
        );
        let path = std::env::temp_dir().join(unique);
        let paths = AllbertPaths::under(path);
        paths.ensure().expect("paths");
        paths
    }

    fn make_executable(path: &std::path::Path) {
        #[cfg(unix)]
        {
            let mut permissions = std::fs::metadata(path).expect("metadata").permissions();
            permissions.set_mode(0o755);
            std::fs::set_permissions(path, permissions).expect("permissions");
        }
    }

    #[test]
    fn enable_list_show_disable_round_trip() {
        let paths = temp_paths("round-trip");
        let bin = paths.root.join("rg");
        std::fs::write(&bin, "not executed").unwrap();
        make_executable(&bin);
        let mut config = Config::default_template();
        config.security.exec_allow.push(bin.display().to_string());
        let result = enable_utility(&paths, &config.security, "rg", Some(&bin)).unwrap();
        assert_eq!(result.entry.id, "rg");
        assert!(list(&paths, true, false)
            .unwrap()
            .contains("offline enabled utilities"));
        assert!(show(&paths, "rg", true, false)
            .unwrap()
            .contains("enabled:     yes"));
        assert!(disable_utility(&paths, "rg").unwrap());
    }
}
