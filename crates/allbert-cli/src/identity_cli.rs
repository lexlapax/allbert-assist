use allbert_kernel_services::{
    add_identity_channel, ensure_identity_record, identity_inconsistencies,
    remove_identity_channel, rename_identity, AllbertPaths, IdentityRecord,
};
use allbert_proto::ChannelKind;
use anyhow::Result;

pub fn show(paths: &AllbertPaths) -> Result<String> {
    let record = ensure_identity_record(paths)?;
    let consistency = identity_inconsistencies(paths, &record)?;
    Ok(render_record(paths, &record, &consistency))
}

pub fn add_channel(paths: &AllbertPaths, kind: ChannelKind, sender: &str) -> Result<String> {
    let record = add_identity_channel(paths, kind, sender)?;
    let consistency = identity_inconsistencies(paths, &record)?;
    Ok(format!(
        "added identity channel binding {}:{}\n\n{}",
        channel_kind_label(kind),
        sender.trim(),
        render_record(paths, &record, &consistency)
    ))
}

pub fn remove_channel(paths: &AllbertPaths, kind: ChannelKind, sender: &str) -> Result<String> {
    let record = remove_identity_channel(paths, kind, sender)?;
    let consistency = identity_inconsistencies(paths, &record)?;
    Ok(format!(
        "removed identity channel binding {}:{}\n\n{}",
        channel_kind_label(kind),
        sender.trim(),
        render_record(paths, &record, &consistency)
    ))
}

pub fn rename(paths: &AllbertPaths, new_name: &str) -> Result<String> {
    let record = rename_identity(paths, new_name)?;
    let consistency = identity_inconsistencies(paths, &record)?;
    Ok(format!(
        "renamed identity to {}\n\n{}",
        record.name,
        render_record(paths, &record, &consistency)
    ))
}

fn render_record(
    paths: &AllbertPaths,
    record: &IdentityRecord,
    consistency: &allbert_kernel_services::IdentityConsistency,
) -> String {
    let mut lines = vec![
        format!("file:              {}", paths.identity_user.display()),
        format!("id:                {}", record.id),
        format!("name:              {}", record.name),
        format!("created at:        {}", record.created_at),
        "channels:".into(),
    ];
    for binding in &record.channels {
        lines.push(format!(
            "- {}:{}",
            channel_kind_label(binding.kind),
            binding.sender
        ));
    }
    lines.push(format!(
        "body:              {}",
        if record.body.trim().is_empty() {
            "(empty)"
        } else {
            "(present)"
        }
    ));
    if !consistency.warnings.is_empty() {
        lines.push("warnings:".into());
        for warning in &consistency.warnings {
            lines.push(format!("- {warning}"));
        }
    }
    if !consistency.migration_candidates.is_empty() {
        lines.push("migration candidates:".into());
        for binding in &consistency.migration_candidates {
            lines.push(format!(
                "- {}:{}",
                channel_kind_label(binding.kind),
                binding.sender
            ));
        }
    }
    lines.join("\n")
}

fn channel_kind_label(kind: ChannelKind) -> &'static str {
    match kind {
        ChannelKind::Cli => "cli",
        ChannelKind::Repl => "repl",
        ChannelKind::Jobs => "jobs",
        ChannelKind::Telegram => "telegram",
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let unique = format!(
                "allbert-identity-cli-{}-{}",
                std::process::id(),
                TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
            );
            let path = std::env::temp_dir().join(unique);
            std::fs::create_dir_all(&path).expect("temp root should create");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.clone())
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn show_surfaces_migration_candidates() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        ensure_identity_record(&paths).expect("seed identity");
        fs::write(&paths.telegram_allowed_chats, "12345\n").expect("write allowlist");

        let rendered = show(&paths).expect("show");
        assert!(rendered.contains("migration candidates:"));
        assert!(rendered.contains("- telegram:12345"));
    }
}
