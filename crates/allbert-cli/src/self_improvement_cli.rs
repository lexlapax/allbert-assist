use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use allbert_kernel_services::{
    collect_worktree_gc, ensure_identity_record, has_pinned_rust_toolchain, render_bytes,
    resolve_source_checkout, resolve_source_checkout_from, resolve_worktree_root,
    worktree_disk_usage, AllbertPaths, Config,
};
use anyhow::{Context, Result};
use sha2::{Digest, Sha256};

use crate::approvals;

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

pub fn diff(paths: &AllbertPaths, approval_id: &str) -> Result<String> {
    let approval = approvals::load(paths, approval_id)?;
    let patch = approval
        .patch
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("approval is not a patch approval: {approval_id}"))?;
    if patch.artifact_path.trim().is_empty() {
        anyhow::bail!("patch approval has no artifact_path: {approval_id}");
    }
    std::fs::read_to_string(&patch.artifact_path)
        .with_context(|| format!("read patch artifact {}", patch.artifact_path))
}

pub fn install(
    paths: &AllbertPaths,
    config: &Config,
    approval_id: &str,
    allow_needs_review: bool,
) -> Result<String> {
    let approval = approvals::load(paths, approval_id)?;
    let patch = approval
        .patch
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("approval is not a patch approval: {approval_id}"))?;
    if approval.status != "accepted" {
        anyhow::bail!(
            "patch approval {} is {}; only accepted approvals can be installed",
            approval.id,
            approval.status
        );
    }
    if patch.overall != "safe-to-merge" && !allow_needs_review {
        anyhow::bail!(
            "patch approval {} is {}; rerun with --allow-needs-review to apply anyway",
            approval.id,
            fallback(&patch.overall)
        );
    }
    if config.self_improvement.install_mode.label() != "apply-to-current-branch" {
        anyhow::bail!(
            "unsupported self_improvement.install_mode: {}",
            config.self_improvement.install_mode.label()
        );
    }
    let source_checkout = resolve_install_source_checkout(paths, config, &patch.source_checkout)?;
    let artifact = PathBuf::from(&patch.artifact_path);
    if !artifact.is_file() {
        anyhow::bail!("patch artifact not found: {}", artifact.display());
    }
    let patch_bytes = std::fs::read(&artifact)
        .with_context(|| format!("read patch artifact {}", artifact.display()))?;
    let patch_sha256 = sha256_hex(&patch_bytes);

    let output = Command::new("git")
        .arg("-C")
        .arg(&source_checkout)
        .arg("apply")
        .arg(&artifact)
        .output()
        .with_context(|| format!("run git apply in {}", source_checkout.display()))?;
    if !output.status.success() {
        anyhow::bail!(
            "git apply failed:\n{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    let source_head_sha = git_rev_parse_head(&source_checkout)?;
    append_install_history(
        paths,
        &approval.id,
        &source_checkout,
        &artifact,
        &source_head_sha,
        &patch_sha256,
    )?;

    Ok(format!(
        "applied patch approval {}\nsource checkout: {}\nsource head: {}\npatch sha256: {}\n\nnext steps:\n- cargo install --path crates/allbert-cli\n- allbert-cli daemon restart",
        approval.id,
        source_checkout.display(),
        source_head_sha,
        patch_sha256
    ))
}

fn display_name(path: &Path) -> String {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(str::to_string)
        .unwrap_or_else(|| path.display().to_string())
}

fn resolve_install_source_checkout(
    paths: &AllbertPaths,
    config: &Config,
    approval_source_checkout: &str,
) -> Result<PathBuf> {
    if !approval_source_checkout.trim().is_empty() {
        return Ok(PathBuf::from(approval_source_checkout));
    }
    Ok(resolve_source_checkout(paths, config)?.path)
}

fn git_rev_parse_head(source_checkout: &Path) -> Result<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(source_checkout)
        .arg("rev-parse")
        .arg("HEAD")
        .output()
        .with_context(|| format!("run git rev-parse in {}", source_checkout.display()))?;
    if !output.status.success() {
        anyhow::bail!(
            "git rev-parse failed:\n{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn append_install_history(
    paths: &AllbertPaths,
    approval_id: &str,
    source_checkout: &Path,
    artifact_path: &Path,
    source_head_sha: &str,
    patch_sha256: &str,
) -> Result<()> {
    if let Some(parent) = paths.self_improvement_history.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let operator = ensure_identity_record(paths)
        .map(|identity| identity.id)
        .unwrap_or_else(|_| "local-operator".into());
    let now = time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into());
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&paths.self_improvement_history)
        .with_context(|| format!("open {}", paths.self_improvement_history.display()))?;
    writeln!(
        file,
        "## {now} {approval_id}\n- operator: {operator}\n- source_checkout: {}\n- source_head_sha: {source_head_sha}\n- patch_sha256: {patch_sha256}\n- artifact_path: {}\n",
        source_checkout.display(),
        artifact_path.display(),
    )
    .with_context(|| format!("append {}", paths.self_improvement_history.display()))?;
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn fallback(value: &str) -> &str {
    if value.trim().is_empty() {
        "(missing)"
    } else {
        value
    }
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

    #[test]
    fn self_improvement_install_applies_accepted_patch_and_logs_history() {
        let temp = TempRoot::new();
        let paths = AllbertPaths::under(temp.path.join(".allbert"));
        paths.ensure().expect("paths should ensure");
        let source = init_git_source(&temp.path.join("source"));
        let artifact = paths
            .sessions
            .join("session-a")
            .join("artifacts")
            .join("approval_patch")
            .join("patch.diff");
        write_readme_patch(&artifact);
        write_patch_approval(
            &paths,
            "approval_patch",
            "accepted",
            "safe-to-merge",
            &source,
            &artifact,
        );

        let rendered = install(&paths, &Config::default_template(), "approval_patch", false)
            .expect("install should apply");

        assert!(rendered.contains("applied patch approval approval_patch"));
        assert_eq!(
            std::fs::read_to_string(source.join("README.md")).expect("readme"),
            "new\n"
        );
        let history = std::fs::read_to_string(&paths.self_improvement_history)
            .expect("history should be written");
        assert!(history.contains("approval_patch"));
        assert!(history.contains("patch_sha256"));
    }

    #[test]
    fn self_improvement_install_refuses_non_accepted_patch() {
        let temp = TempRoot::new();
        let paths = AllbertPaths::under(temp.path.join(".allbert"));
        paths.ensure().expect("paths should ensure");
        let source = init_git_source(&temp.path.join("source"));
        let artifact = paths
            .sessions
            .join("session-a")
            .join("artifacts")
            .join("approval_patch")
            .join("patch.diff");
        write_readme_patch(&artifact);
        write_patch_approval(
            &paths,
            "approval_patch",
            "pending",
            "safe-to-merge",
            &source,
            &artifact,
        );

        let err = install(&paths, &Config::default_template(), "approval_patch", false)
            .expect_err("pending approval should not install")
            .to_string();

        assert!(err.contains("only accepted approvals can be installed"));
        assert_eq!(
            std::fs::read_to_string(source.join("README.md")).expect("readme"),
            "old\n"
        );
    }

    #[test]
    fn self_improvement_install_refuses_needs_review_without_override() {
        let temp = TempRoot::new();
        let paths = AllbertPaths::under(temp.path.join(".allbert"));
        paths.ensure().expect("paths should ensure");
        let source = init_git_source(&temp.path.join("source"));
        let artifact = paths
            .sessions
            .join("session-a")
            .join("artifacts")
            .join("approval_patch")
            .join("patch.diff");
        write_readme_patch(&artifact);
        write_patch_approval(
            &paths,
            "approval_patch",
            "accepted",
            "needs-review",
            &source,
            &artifact,
        );

        let err = install(&paths, &Config::default_template(), "approval_patch", false)
            .expect_err("needs-review approval should require override")
            .to_string();

        assert!(err.contains("--allow-needs-review"));
        assert_eq!(
            std::fs::read_to_string(source.join("README.md")).expect("readme"),
            "old\n"
        );
    }

    #[test]
    fn self_improvement_install_diff_renders_patch_for_safe_and_needs_review() {
        let temp = TempRoot::new();
        let paths = AllbertPaths::under(temp.path.join(".allbert"));
        paths.ensure().expect("paths should ensure");
        let source = init_git_source(&temp.path.join("source"));
        for (approval_id, overall) in [
            ("approval_safe", "safe-to-merge"),
            ("approval_review", "needs-review"),
        ] {
            let artifact = paths
                .sessions
                .join("session-a")
                .join("artifacts")
                .join(approval_id)
                .join("patch.diff");
            write_readme_patch(&artifact);
            write_patch_approval(&paths, approval_id, "accepted", overall, &source, &artifact);

            let rendered = diff(&paths, approval_id).expect("diff should render");

            assert!(rendered.contains("diff --git a/README.md b/README.md"));
            assert!(rendered.contains("+new"));
        }
    }

    fn init_git_source(root: &Path) -> PathBuf {
        std::fs::create_dir_all(root).expect("source root should create");
        std::fs::write(root.join("README.md"), "old\n").expect("readme should write");
        run_git(Command::new("git").arg("init").current_dir(root));
        run_git(
            Command::new("git")
                .arg("config")
                .arg("user.email")
                .arg("allbert@example.invalid")
                .current_dir(root),
        );
        run_git(
            Command::new("git")
                .arg("config")
                .arg("user.name")
                .arg("Allbert Test")
                .current_dir(root),
        );
        run_git(Command::new("git").arg("add").arg(".").current_dir(root));
        run_git(
            Command::new("git")
                .arg("commit")
                .arg("-m")
                .arg("initial")
                .current_dir(root),
        );
        root.to_path_buf()
    }

    fn run_git(command: &mut Command) {
        let output = command.output().expect("git command should spawn");
        assert!(
            output.status.success(),
            "git command failed:\n{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn write_readme_patch(path: &Path) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).expect("artifact parent should create");
        }
        std::fs::write(
            path,
            "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new\n",
        )
        .expect("patch should write");
    }

    fn write_patch_approval(
        paths: &AllbertPaths,
        approval_id: &str,
        status: &str,
        overall: &str,
        source_checkout: &Path,
        artifact_path: &Path,
    ) {
        let dir = paths.sessions.join("session-a").join("approvals");
        std::fs::create_dir_all(&dir).expect("approval dir should create");
        let content = format!(
            "---\nid: {approval_id}\nsession_id: session-a\nchannel: repl\nsender: local\nagent: allbert/root\ntool: rust-rebuild\nrequest_id: 42\nkind: patch-approval\nrequested_at: 2026-04-20T10:00:00Z\nexpires_at: 2026-04-20T11:00:00Z\nstatus: {status}\nsource_checkout: {}\nbranch: allbert-rebuild-test\nworktree_path: /tmp/worktree\nvalidation: passed\noverall: {overall}\nartifact_path: {}\n---\n\nPatch summary for approval.\n",
            source_checkout.display(),
            artifact_path.display()
        );
        std::fs::write(dir.join(format!("{approval_id}.md")), content)
            .expect("approval should write");
    }
}
