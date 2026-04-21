use std::path::PathBuf;
use std::process::Command;

use allbert_kernel::{load_heartbeat_record, validate_heartbeat_record, AllbertPaths};
use allbert_proto::ChannelKind;
use anyhow::{Context, Result};

pub fn show(paths: &AllbertPaths) -> Result<String> {
    let record = load_heartbeat_record(paths)?;
    let validation = validate_heartbeat_record(&record);
    let mut lines = vec![
        format!("file:              {}", paths.heartbeat.display()),
        format!("timezone:          {}", record.timezone),
        format!(
            "primary_channel:   {}",
            channel_label(record.primary_channel)
        ),
        "quiet_hours:".into(),
    ];
    for range in &record.quiet_hours {
        lines.push(format!("- {range}"));
    }
    lines.push(format!(
        "body:              {}",
        if record.body.trim().is_empty() {
            "(empty)"
        } else {
            "(present)"
        }
    ));

    if !validation.warnings.is_empty() {
        lines.push("warnings:".into());
        for warning in validation.warnings {
            lines.push(format!("- {warning}"));
        }
    }

    Ok(lines.join("\n"))
}

pub fn edit(paths: &AllbertPaths) -> Result<String> {
    let editor = std::env::var("EDITOR").unwrap_or_else(|_| "vi".into());
    let status = Command::new(&editor)
        .arg(&paths.heartbeat)
        .status()
        .with_context(|| format!("launch editor `{editor}`"))?;
    if !status.success() {
        anyhow::bail!("editor `{editor}` exited with {status}");
    }
    Ok(format!("updated {}", paths.heartbeat.display()))
}

pub fn suggest(paths: &AllbertPaths, channel: Option<ChannelKind>) -> Result<String> {
    let preferred = channel.unwrap_or(ChannelKind::Repl);
    let rendered = format!(
        "---\nversion: 1\ntimezone: UTC\nprimary_channel: {}\nquiet_hours:\n  - \"22:00-07:00\"\ncheck_ins:\n  daily_brief:\n    enabled: false\n  weekly_review:\n    enabled: false\ninbox_nag:\n  enabled: true\n  cadence: daily\n  time: \"09:00\"\n  channel: {}\n---\n\n# HEARTBEAT\n\nSuggested template for this profile.\n",
        channel_label(preferred),
        channel_label(preferred)
    );

    let scratch = heartbeat_scratch_path(paths);
    if let Some(parent) = scratch.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    std::fs::write(&scratch, rendered).with_context(|| format!("write {}", scratch.display()))?;
    Ok(format!(
        "wrote heartbeat suggestion to {}\nreview and copy into {} when ready",
        scratch.display(),
        paths.heartbeat.display()
    ))
}

fn heartbeat_scratch_path(paths: &AllbertPaths) -> PathBuf {
    paths
        .root
        .join(".tmp")
        .join(format!("heartbeat-suggest-{}.md", std::process::id()))
}

fn channel_label(kind: ChannelKind) -> &'static str {
    match kind {
        ChannelKind::Cli => "cli",
        ChannelKind::Repl => "repl",
        ChannelKind::Jobs => "jobs",
        ChannelKind::Telegram => "telegram",
    }
}
