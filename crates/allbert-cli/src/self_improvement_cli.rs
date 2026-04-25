use std::path::{Path, PathBuf};

use allbert_kernel::{
    collect_worktree_gc, has_pinned_rust_toolchain, render_bytes, resolve_source_checkout,
    resolve_source_checkout_from, resolve_worktree_root, worktree_disk_usage, AllbertPaths, Config,
};
use anyhow::{Context, Result};

pub fn config_show(paths: &AllbertPaths, config: &Config) -> Result<String> {
    let checkout = resolve_source_checkout(paths, config).ok();
    let worktree_root = resolve_worktree_root(paths, &config.self_improvement);
    let usage = worktree_disk_usage(paths, &config.self_improvement)?;
    let mut lines = vec!["self-improvement:".to_string()];
    match checkout {
        Some(checkout) => {
            lines.push(format!("source checkout: {}", checkout.path.display()));
            lines.push(format!("source:          {}", checkout.source.label()));
            lines.push(format!(
                "rust toolchain:  {}",
                if has_pinned_rust_toolchain(&checkout.path) {
                    "pinned"
                } else {
                    "missing rust-toolchain.toml"
                }
            ));
        }
        None => {
            lines.push("source checkout: unresolved".into());
            lines.push(
                "hint:            run `allbert-cli self-improvement config set --source-checkout <path>`"
                    .into(),
            );
        }
    }
    lines.push(format!("worktree root:   {}", worktree_root.display()));
    lines.push(format!(
        "worktree disk:   {} / {} across {} worktree(s)",
        render_bytes(usage.total_bytes),
        render_bytes(usage.cap_bytes),
        usage.entries.len()
    ));
    lines.push(format!(
        "install mode:    {}",
        config.self_improvement.install_mode.label()
    ));
    lines.push(format!(
        "keep rejected:   {}",
        if config.self_improvement.keep_rejected_worktree {
            "yes"
        } else {
            "no"
        }
    ));
    Ok(lines.join("\n"))
}

pub fn config_set_source_checkout(
    paths: &AllbertPaths,
    config: &Config,
    source_checkout: &str,
) -> Result<String> {
    let mut updated = config.clone();
    updated.self_improvement.source_checkout = Some(PathBuf::from(source_checkout));
    let resolved = resolve_source_checkout_from(paths, &updated.self_improvement, None, None)
        .with_context(|| format!("resolve source checkout {}", source_checkout))?;
    updated.self_improvement.source_checkout = Some(resolved.path.clone());
    updated.persist(paths)?;

    let mut lines = vec![format!(
        "configured self-improvement source checkout: {}",
        resolved.path.display()
    )];
    if has_pinned_rust_toolchain(&resolved.path) {
        lines.push("rust toolchain: pinned".into());
    } else {
        lines.push(
            "rust toolchain: missing rust-toolchain.toml; rust-rebuild will refuse activation until it is added."
                .into(),
        );
    }
    Ok(lines.join("\n"))
}

pub fn gc(paths: &AllbertPaths, config: &Config, dry_run: bool) -> Result<String> {
    let report = collect_worktree_gc(paths, &config.self_improvement, dry_run)?;
    let mut lines = vec![format!(
        "self-improvement worktree gc ({})",
        if dry_run { "dry run" } else { "apply" }
    )];
    lines.push(format!("root: {}", report.root.display()));
    if report.entries.is_empty() {
        lines.push("worktrees: none".into());
    } else {
        lines.push("worktrees:".into());
        for entry in &report.entries {
            lines.push(format!(
                "- {}  size={}  stale={}",
                display_name(&entry.path),
                render_bytes(entry.bytes),
                if entry.stale { "yes" } else { "no" }
            ));
        }
    }
    if dry_run {
        let reclaimable = report
            .entries
            .iter()
            .filter(|entry| entry.stale)
            .map(|entry| entry.bytes)
            .sum::<u64>();
        let reclaimable_count = report.entries.iter().filter(|entry| entry.stale).count();
        lines.push(format!(
            "would reclaim: {} from {} stale worktree(s)",
            render_bytes(reclaimable),
            reclaimable_count
        ));
    } else {
        lines.push(format!(
            "reclaimed: {} from {} stale worktree(s)",
            render_bytes(report.reclaimed_bytes),
            report.reclaimed_entries
        ));
    }
    Ok(lines.join("\n"))
}

fn display_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(str::to_string)
        .unwrap_or_else(|| path.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let unique = format!(
                "allbert-cli-self-improvement-test-{}-{}",
                std::process::id(),
                counter
            );
            let path = std::env::temp_dir().join(unique);
            std::fs::create_dir_all(&path).expect("temp root should be created");
            Self { path }
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn config_show_renders_fixture_profile_without_source_checkout() {
        let temp = TempRoot::new();
        let paths = AllbertPaths::under(temp.path.join(".allbert"));
        let config = Config::load_or_create(&paths).expect("config");
        let rendered = config_show(&paths, &config).expect("render");
        assert!(rendered.contains("source checkout:"));
        assert!(rendered.contains("worktree root:"));
        assert!(rendered.contains("worktree disk:"));
    }
}
