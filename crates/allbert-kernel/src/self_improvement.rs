use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Command;

use serde::Serialize;
use serde_json::json;
use uuid::Uuid;

use crate::atomic_write;
use crate::config::{Config, SelfImprovementConfig};
use crate::error::KernelError;
use crate::paths::AllbertPaths;

const BYTES_PER_GIB: u64 = 1024 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceCheckoutSource {
    Config,
    Env,
    ExecutableWalk,
}

impl SourceCheckoutSource {
    pub fn label(self) -> &'static str {
        match self {
            Self::Config => "config",
            Self::Env => "env",
            Self::ExecutableWalk => "executable-walk",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ResolvedSourceCheckout {
    pub path: PathBuf,
    pub source: SourceCheckoutSource,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorktreeDiskEntry {
    pub path: PathBuf,
    pub bytes: u64,
    pub stale: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorktreeDiskUsage {
    pub root: PathBuf,
    pub entries: Vec<WorktreeDiskEntry>,
    pub total_bytes: u64,
    pub cap_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorktreeGcReport {
    pub root: PathBuf,
    pub dry_run: bool,
    pub entries: Vec<WorktreeDiskEntry>,
    pub reclaimed_entries: usize,
    pub reclaimed_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RebuildWorktree {
    pub branch: String,
    pub path: PathBuf,
    pub source_checkout: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ValidationCommand {
    pub label: String,
    pub program: String,
    pub args: Vec<String>,
    pub env_remove: Vec<String>,
    pub env: Vec<(String, String)>,
}

impl ValidationCommand {
    pub fn new(label: impl Into<String>, program: impl Into<String>, args: Vec<String>) -> Self {
        Self {
            label: label.into(),
            program: program.into(),
            args,
            env_remove: Vec::new(),
            env: Vec::new(),
        }
    }

    pub fn without_env(mut self, name: impl Into<String>) -> Self {
        self.env_remove.push(name.into());
        self
    }

    pub fn with_env(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.env.push((name.into(), value.into()));
        self
    }

    pub fn rendered(&self) -> String {
        let mut parts = vec![self.program.clone()];
        parts.extend(self.args.iter().cloned());
        parts.join(" ")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ValidationOverall {
    SafeToMerge,
    NeedsReview,
}

impl ValidationOverall {
    pub fn label(&self) -> &'static str {
        match self {
            Self::SafeToMerge => "safe-to-merge",
            Self::NeedsReview => "needs-review",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ValidationStepResult {
    pub label: String,
    pub command: String,
    pub success: bool,
    pub exit_code: Option<i32>,
    pub stdout_tail: String,
    pub stderr_tail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TierAValidationReport {
    pub worktree_path: PathBuf,
    pub overall: ValidationOverall,
    pub steps: Vec<ValidationStepResult>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PatchArtifact {
    pub artifact_id: String,
    pub path: PathBuf,
    pub bytes: u64,
}

pub fn resolve_source_checkout(
    paths: &AllbertPaths,
    config: &Config,
) -> Result<ResolvedSourceCheckout, KernelError> {
    let env = std::env::var_os("ALLBERT_SOURCE_CHECKOUT").map(PathBuf::from);
    let executable = std::env::current_exe().ok();
    resolve_source_checkout_from(
        paths,
        &config.self_improvement,
        env.as_deref(),
        executable.as_deref(),
    )
}

pub fn resolve_source_checkout_from(
    paths: &AllbertPaths,
    config: &SelfImprovementConfig,
    env_source_checkout: Option<&Path>,
    executable_path: Option<&Path>,
) -> Result<ResolvedSourceCheckout, KernelError> {
    if let Some(configured) = config.source_checkout.as_deref() {
        let resolved = resolve_source_checkout_path(paths, configured);
        return resolve_source_checkout_candidate(&resolved, SourceCheckoutSource::Config);
    }

    if let Some(env_checkout) = env_source_checkout.filter(|path| !path.as_os_str().is_empty()) {
        let resolved = resolve_source_checkout_path(paths, env_checkout);
        return resolve_source_checkout_candidate(&resolved, SourceCheckoutSource::Env);
    }

    if let Some(executable_path) = executable_path {
        if let Some(path) = find_source_checkout_from_executable(executable_path) {
            return Ok(ResolvedSourceCheckout {
                path,
                source: SourceCheckoutSource::ExecutableWalk,
            });
        }
    }

    Err(source_checkout_refusal())
}

pub fn assert_rust_rebuild_ready(
    paths: &AllbertPaths,
    config: &Config,
) -> Result<ResolvedSourceCheckout, KernelError> {
    let checkout = resolve_source_checkout(paths, config)?;
    if !has_pinned_rust_toolchain(&checkout.path) {
        return Err(KernelError::InitFailed(format!(
            "rust-rebuild requires a pinned Rust toolchain in {}. Add rust-toolchain.toml before activating self-improvement.",
            checkout.path.display()
        )));
    }
    Ok(checkout)
}

pub fn has_pinned_rust_toolchain(source_checkout: &Path) -> bool {
    source_checkout.join("rust-toolchain.toml").is_file()
        || source_checkout.join("rust-toolchain").is_file()
}

pub fn resolve_worktree_root(paths: &AllbertPaths, config: &SelfImprovementConfig) -> PathBuf {
    resolve_profile_aware_path(paths, &config.worktree_root)
}

pub fn worktree_disk_usage(
    paths: &AllbertPaths,
    config: &SelfImprovementConfig,
) -> Result<WorktreeDiskUsage, KernelError> {
    let root = resolve_worktree_root(paths, config);
    worktree_disk_usage_at(root, worktree_cap_bytes(config))
}

pub fn ensure_worktree_creation_allowed(
    paths: &AllbertPaths,
    config: &SelfImprovementConfig,
) -> Result<WorktreeDiskUsage, KernelError> {
    let usage = worktree_disk_usage(paths, config)?;
    ensure_worktree_capacity_bytes(&usage.root, usage.total_bytes, usage.cap_bytes, 0)?;
    Ok(usage)
}

pub fn check_self_improvement_write_target(
    target: &Path,
    worktree: &Path,
    source_checkout: &Path,
    paths: &AllbertPaths,
) -> Result<PathBuf, String> {
    let target = normalize_path(&absolute_path(target)?);
    let worktree = normalize_path(&absolute_path(worktree)?);
    let source_checkout = normalize_path(&absolute_path(source_checkout)?);
    let profile_root = normalize_path(&absolute_path(&paths.root)?);
    let rust_rebuild_skill = source_checkout.join("skills").join("rust-rebuild");

    if target.starts_with(&worktree) {
        assert_existing_parent_stays_under(&target, &worktree)?;
        return Ok(target);
    }

    if target.starts_with(&rust_rebuild_skill) {
        return Err(format!(
            "self-improvement cannot write to its own rust-rebuild skill source at {}",
            rust_rebuild_skill.display()
        ));
    }

    if target.starts_with(&source_checkout) {
        return Err(format!(
            "self-improvement writes are restricted to the active worktree; attempted source checkout path {}",
            target.display()
        ));
    }

    if target.starts_with(&profile_root) {
        return Err(format!(
            "self-improvement writes are restricted to the active worktree; attempted profile path {}",
            target.display()
        ));
    }

    Err(format!(
        "self-improvement writes are restricted to the active worktree {}; attempted {}",
        worktree.display(),
        target.display()
    ))
}

pub fn collect_worktree_gc(
    paths: &AllbertPaths,
    config: &SelfImprovementConfig,
    dry_run: bool,
) -> Result<WorktreeGcReport, KernelError> {
    let usage = worktree_disk_usage(paths, config)?;
    let mut reclaimed_entries = 0usize;
    let mut reclaimed_bytes = 0u64;

    if !dry_run {
        for entry in &usage.entries {
            if !entry.stale {
                continue;
            }
            fs::remove_dir_all(&entry.path).map_err(|err| {
                KernelError::InitFailed(format!(
                    "remove stale worktree {}: {err}",
                    entry.path.display()
                ))
            })?;
            reclaimed_entries += 1;
            reclaimed_bytes = reclaimed_bytes.saturating_add(entry.bytes);
        }
    }

    Ok(WorktreeGcReport {
        root: usage.root,
        dry_run,
        entries: usage.entries,
        reclaimed_entries,
        reclaimed_bytes,
    })
}

pub fn create_rust_rebuild_worktree(
    paths: &AllbertPaths,
    config: &Config,
    branch_hint: Option<&str>,
) -> Result<RebuildWorktree, KernelError> {
    let source = assert_rust_rebuild_ready(paths, config)?;
    let _usage = ensure_worktree_creation_allowed(paths, &config.self_improvement)?;
    let worktree_root = resolve_worktree_root(paths, &config.self_improvement);
    fs::create_dir_all(&worktree_root).map_err(|err| {
        KernelError::InitFailed(format!("create {}: {err}", worktree_root.display()))
    })?;

    let branch = unique_rebuild_branch(branch_hint);
    let worktree_path = worktree_root.join(&branch);
    run_command_checked(
        Command::new("git")
            .arg("-C")
            .arg(&source.path)
            .arg("worktree")
            .arg("add")
            .arg("-b")
            .arg(&branch)
            .arg(&worktree_path)
            .arg("HEAD"),
        "git worktree add",
    )?;

    let metadata = json!({
        "branch": branch,
        "source_checkout": source.path,
        "created_by": "allbert-rust-rebuild",
    });
    let metadata_path = worktree_path.join(".allbert-worktree.json");
    atomic_write(
        &metadata_path,
        serde_json::to_string_pretty(&metadata)
            .map_err(|err| KernelError::InitFailed(format!("serialize worktree metadata: {err}")))?
            .as_bytes(),
    )
    .map_err(|err| KernelError::InitFailed(format!("write {}: {err}", metadata_path.display())))?;

    Ok(RebuildWorktree {
        branch,
        path: worktree_path,
        source_checkout: source.path,
    })
}

pub fn tier_a_validation_commands(temp_home: &Path) -> Vec<ValidationCommand> {
    vec![
        ValidationCommand::new("cargo fmt", "cargo", vec!["fmt".into(), "--check".into()]),
        ValidationCommand::new(
            "cargo clippy",
            "cargo",
            vec![
                "clippy".into(),
                "--workspace".into(),
                "--all-targets".into(),
                "--".into(),
                "-D".into(),
                "warnings".into(),
            ],
        )
        .without_env("RUSTC_WRAPPER"),
        ValidationCommand::new("cargo test", "cargo", vec!["test".into(), "-q".into()])
            .without_env("RUSTC_WRAPPER"),
        ValidationCommand::new(
            "cli help",
            "cargo",
            vec![
                "run".into(),
                "-q".into(),
                "-p".into(),
                "allbert-cli".into(),
                "--".into(),
                "--help".into(),
            ],
        )
        .without_env("RUSTC_WRAPPER"),
        ValidationCommand::new(
            "temp-home daemon status smoke",
            "cargo",
            vec![
                "run".into(),
                "-q".into(),
                "-p".into(),
                "allbert-cli".into(),
                "--".into(),
                "daemon".into(),
                "status".into(),
            ],
        )
        .without_env("RUSTC_WRAPPER")
        .with_env("ALLBERT_HOME", temp_home.display().to_string()),
    ]
}

pub fn run_tier_a_validation(worktree_path: &Path) -> TierAValidationReport {
    let temp_home = std::env::temp_dir().join(format!(
        "allbert-rust-rebuild-tier-a-{}",
        Uuid::new_v4().simple()
    ));
    let commands = tier_a_validation_commands(&temp_home);
    let report = run_validation_commands(worktree_path, &commands);
    let _ = fs::remove_dir_all(temp_home);
    report
}

pub fn run_validation_commands(
    worktree_path: &Path,
    commands: &[ValidationCommand],
) -> TierAValidationReport {
    let mut steps = Vec::new();
    for validation in commands {
        let mut command = Command::new(&validation.program);
        command.current_dir(worktree_path);
        command.args(&validation.args);
        for name in &validation.env_remove {
            command.env_remove(name);
        }
        for (name, value) in &validation.env {
            command.env(name, value);
        }
        let output = command.output();
        let step = match output {
            Ok(output) => ValidationStepResult {
                label: validation.label.clone(),
                command: validation.rendered(),
                success: output.status.success(),
                exit_code: output.status.code(),
                stdout_tail: truncate_tail(&String::from_utf8_lossy(&output.stdout), 4000),
                stderr_tail: truncate_tail(&String::from_utf8_lossy(&output.stderr), 4000),
            },
            Err(err) => ValidationStepResult {
                label: validation.label.clone(),
                command: validation.rendered(),
                success: false,
                exit_code: None,
                stdout_tail: String::new(),
                stderr_tail: err.to_string(),
            },
        };
        steps.push(step);
    }
    let overall = if steps.iter().all(|step| step.success) {
        ValidationOverall::SafeToMerge
    } else {
        ValidationOverall::NeedsReview
    };
    TierAValidationReport {
        worktree_path: worktree_path.to_path_buf(),
        overall,
        steps,
    }
}

pub fn emit_patch_artifact(
    paths: &AllbertPaths,
    worktree_path: &Path,
    session_id: &str,
    artifact_id: Option<&str>,
) -> Result<PatchArtifact, KernelError> {
    run_command_checked(
        Command::new("git")
            .arg("-C")
            .arg(worktree_path)
            .arg("add")
            .arg("-N")
            .arg("."),
        "git add -N",
    )?;
    let output = Command::new("git")
        .arg("-C")
        .arg(worktree_path)
        .arg("diff")
        .arg("--binary")
        .arg("--no-ext-diff")
        .output()
        .map_err(|err| KernelError::InitFailed(format!("run git diff: {err}")))?;
    if !output.status.success() {
        return Err(KernelError::InitFailed(format!(
            "git diff failed: {}",
            String::from_utf8_lossy(&output.stderr)
        )));
    }

    let artifact_id = artifact_id
        .map(str::to_string)
        .unwrap_or_else(|| format!("rust-rebuild-{}", Uuid::new_v4().simple()));
    let artifact_dir = paths
        .sessions
        .join(session_id)
        .join("artifacts")
        .join(&artifact_id);
    fs::create_dir_all(&artifact_dir).map_err(|err| {
        KernelError::InitFailed(format!("create {}: {err}", artifact_dir.display()))
    })?;
    let path = artifact_dir.join("patch.diff");
    atomic_write(&path, &output.stdout)
        .map_err(|err| KernelError::InitFailed(format!("write {}: {err}", path.display())))?;
    Ok(PatchArtifact {
        artifact_id,
        path,
        bytes: output.stdout.len() as u64,
    })
}

fn resolve_source_checkout_candidate(
    candidate: &Path,
    source: SourceCheckoutSource,
) -> Result<ResolvedSourceCheckout, KernelError> {
    match find_source_checkout_root(candidate) {
        Some(path) => Ok(ResolvedSourceCheckout { path, source }),
        None => Err(KernelError::InitFailed(format!(
            "{} is not a valid Allbert source checkout. Run `allbert-cli self-improvement config set --source-checkout <path>` with a checkout containing crates/allbert-kernel.",
            candidate.display()
        ))),
    }
}

fn unique_rebuild_branch(branch_hint: Option<&str>) -> String {
    let hint = branch_hint
        .map(sanitize_branch_component)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "patch".into());
    format!("allbert-rebuild-{hint}-{}", Uuid::new_v4().simple())
}

fn sanitize_branch_component(raw: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in raw.chars() {
        let normalized = if ch.is_ascii_alphanumeric() {
            ch.to_ascii_lowercase()
        } else {
            '-'
        };
        if normalized == '-' {
            if !last_dash {
                out.push('-');
            }
            last_dash = true;
        } else {
            out.push(normalized);
            last_dash = false;
        }
    }
    out.trim_matches('-').chars().take(40).collect()
}

fn run_command_checked(command: &mut Command, label: &str) -> Result<(), KernelError> {
    let output = command
        .output()
        .map_err(|err| KernelError::InitFailed(format!("run {label}: {err}")))?;
    if output.status.success() {
        return Ok(());
    }
    Err(KernelError::InitFailed(format!(
        "{label} failed with status {}:\n{}{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )))
}

fn find_source_checkout_from_executable(executable_path: &Path) -> Option<PathBuf> {
    let canonical = executable_path
        .canonicalize()
        .unwrap_or_else(|_| executable_path.to_path_buf());
    let start = if canonical.is_file() {
        canonical.parent()?.to_path_buf()
    } else {
        canonical
    };
    find_source_checkout_root(&start)
}

fn find_source_checkout_root(start: &Path) -> Option<PathBuf> {
    let start = if start.is_file() {
        start.parent()?.to_path_buf()
    } else {
        start.to_path_buf()
    };
    for candidate in start.ancestors() {
        if workspace_has_allbert_kernel(candidate) {
            return candidate
                .canonicalize()
                .ok()
                .or_else(|| Some(candidate.to_path_buf()));
        }
    }
    None
}

fn workspace_has_allbert_kernel(root: &Path) -> bool {
    if !root.join(".git").exists() {
        return false;
    }
    let manifest_path = root.join("Cargo.toml");
    let Ok(raw) = fs::read_to_string(&manifest_path) else {
        return false;
    };
    let Ok(parsed) = raw.parse::<toml::Value>() else {
        return false;
    };
    let Some(members) = parsed
        .get("workspace")
        .and_then(|workspace| workspace.get("members"))
        .and_then(|members| members.as_array())
    else {
        return false;
    };

    members
        .iter()
        .filter_map(|member| member.as_str())
        .any(|member| {
            let normalized = member.replace('\\', "/");
            normalized.ends_with("crates/allbert-kernel")
                || member_manifest_package_name(root, member).as_deref() == Some("allbert-kernel")
        })
}

fn member_manifest_package_name(root: &Path, member: &str) -> Option<String> {
    let manifest = root.join(member).join("Cargo.toml");
    let raw = fs::read_to_string(manifest).ok()?;
    let parsed = raw.parse::<toml::Value>().ok()?;
    parsed
        .get("package")
        .and_then(|package| package.get("name"))
        .and_then(|name| name.as_str())
        .map(str::to_string)
}

fn source_checkout_refusal() -> KernelError {
    KernelError::InitFailed(
        "self-improvement source checkout is not configured. Run `allbert-cli self-improvement config set --source-checkout <path>` or set ALLBERT_SOURCE_CHECKOUT before activating rust-rebuild.".into(),
    )
}

fn resolve_profile_aware_path(paths: &AllbertPaths, raw: &Path) -> PathBuf {
    let rendered = raw.display().to_string();
    if rendered == "~/.allbert" {
        return paths.root.clone();
    }
    if let Some(rest) = rendered.strip_prefix("~/.allbert/") {
        return paths.root.join(rest);
    }
    if let Some(rest) = rendered.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    if raw.is_absolute() {
        raw.to_path_buf()
    } else {
        paths.root.join(raw)
    }
}

fn resolve_source_checkout_path(paths: &AllbertPaths, raw: &Path) -> PathBuf {
    let rendered = raw.display().to_string();
    if rendered == "~/.allbert" {
        return paths.root.clone();
    }
    if let Some(rest) = rendered.strip_prefix("~/.allbert/") {
        return paths.root.join(rest);
    }
    if let Some(rest) = rendered.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    if raw.is_absolute() {
        raw.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(raw))
            .unwrap_or_else(|_| raw.to_path_buf())
    }
}

fn worktree_cap_bytes(config: &SelfImprovementConfig) -> u64 {
    u64::from(config.max_worktree_gb).saturating_mul(BYTES_PER_GIB)
}

fn worktree_disk_usage_at(root: PathBuf, cap_bytes: u64) -> Result<WorktreeDiskUsage, KernelError> {
    let mut entries = Vec::new();
    let mut total_bytes = 0u64;

    if root.exists() {
        for entry in fs::read_dir(&root)
            .map_err(|err| KernelError::InitFailed(format!("read {}: {err}", root.display())))?
        {
            let entry = entry.map_err(KernelError::Io)?;
            let file_type = entry.file_type().map_err(KernelError::Io)?;
            if !file_type.is_dir() {
                continue;
            }
            let path = entry.path();
            let bytes = directory_size(&path)?;
            total_bytes = total_bytes.saturating_add(bytes);
            entries.push(WorktreeDiskEntry {
                stale: is_stale_worktree(&path),
                path,
                bytes,
            });
        }
    }

    entries.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(WorktreeDiskUsage {
        root,
        entries,
        total_bytes,
        cap_bytes,
    })
}

fn ensure_worktree_capacity_bytes(
    root: &Path,
    current_bytes: u64,
    cap_bytes: u64,
    additional_bytes: u64,
) -> Result<(), KernelError> {
    let projected = current_bytes.saturating_add(additional_bytes);
    if projected > cap_bytes {
        return Err(KernelError::InitFailed(format!(
            "self-improvement worktree disk cap exceeded at {}: projected {} exceeds cap {}. Run `allbert-cli self-improvement gc --dry-run` to inspect and `allbert-cli self-improvement gc` to reclaim stale worktrees.",
            root.display(),
            render_bytes(projected),
            render_bytes(cap_bytes)
        )));
    }
    Ok(())
}

fn is_stale_worktree(path: &Path) -> bool {
    path.join(".allbert-stale").exists() || path.join(".allbert-rejected").exists()
}

fn directory_size(path: &Path) -> Result<u64, KernelError> {
    let metadata = fs::symlink_metadata(path).map_err(KernelError::Io)?;
    if metadata.is_file() {
        return Ok(metadata.len());
    }
    if metadata.file_type().is_symlink() {
        return Ok(0);
    }
    if !metadata.is_dir() {
        return Ok(0);
    }

    let mut total = 0u64;
    for entry in fs::read_dir(path)
        .map_err(|err| KernelError::InitFailed(format!("read {}: {err}", path.display())))?
    {
        let entry = entry.map_err(KernelError::Io)?;
        total = total.saturating_add(directory_size(&entry.path())?);
    }
    Ok(total)
}

fn absolute_path(path: &Path) -> Result<PathBuf, String> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .map_err(|err| format!("resolve current dir: {err}"))
    }
}

fn normalize_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::RootDir | Component::Prefix(_) | Component::Normal(_) => {
                normalized.push(component.as_os_str());
            }
        }
    }
    normalized
}

fn nearest_existing_ancestor(path: &Path) -> Option<PathBuf> {
    let mut current = path.to_path_buf();
    loop {
        if current.exists() {
            return Some(current);
        }
        current = current.parent()?.to_path_buf();
    }
}

fn assert_existing_parent_stays_under(target: &Path, root: &Path) -> Result<(), String> {
    let root = root
        .canonicalize()
        .map_err(|err| format!("canonicalize worktree {}: {err}", root.display()))?;
    let Some(existing) = nearest_existing_ancestor(target) else {
        return Err(format!("no existing ancestor for {}", target.display()));
    };
    let existing = existing
        .canonicalize()
        .map_err(|err| format!("canonicalize {}: {err}", existing.display()))?;
    if existing.starts_with(&root) {
        Ok(())
    } else {
        Err(format!(
            "self-improvement target {} escapes the active worktree through a symlinked parent",
            target.display()
        ))
    }
}

pub fn render_bytes(bytes: u64) -> String {
    if bytes >= BYTES_PER_GIB {
        format!("{:.2} GiB", bytes as f64 / BYTES_PER_GIB as f64)
    } else if bytes >= 1024 * 1024 {
        format!("{:.2} MiB", bytes as f64 / (1024.0 * 1024.0))
    } else if bytes >= 1024 {
        format!("{:.2} KiB", bytes as f64 / 1024.0)
    } else {
        format!("{bytes} B")
    }
}

fn truncate_tail(raw: &str, max_bytes: usize) -> String {
    if raw.len() <= max_bytes {
        return raw.to_string();
    }
    let start = raw
        .char_indices()
        .map(|(idx, _)| idx)
        .find(|idx| raw.len() - idx <= max_bytes)
        .unwrap_or(raw.len());
    format!("[truncated]\n{}", &raw[start..])
}

#[cfg(test)]
fn write_fixture_file(path: &Path, content: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("fixture parent should be created");
    }
    fs::write(path, content).expect("fixture file should be written");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_paths(root: &Path) -> AllbertPaths {
        AllbertPaths::under(root.join(".allbert"))
    }

    fn write_workspace(root: &Path, kernel_member: &str, kernel_package: &str) {
        fs::create_dir_all(root.join(".git")).expect("git metadata should be created");
        write_fixture_file(
            &root.join("Cargo.toml"),
            &format!(
                r#"[workspace]
members = ["{kernel_member}"]
"#
            ),
        );
        write_fixture_file(
            &root.join(kernel_member).join("Cargo.toml"),
            &format!(
                r#"[package]
name = "{kernel_package}"
version = "0.0.0"
edition = "2021"
"#
            ),
        );
    }

    fn write_rust_rebuild_fixture_source(root: &Path) {
        write_fixture_file(
            &root.join("Cargo.toml"),
            r#"[workspace]
members = [
    "crates/allbert-kernel",
    "crates/allbert-cli"
]
resolver = "2"
"#,
        );
        write_fixture_file(
            &root.join("rust-toolchain.toml"),
            include_str!("../../../rust-toolchain.toml"),
        );
        write_fixture_file(&root.join(".gitignore"), "target/\n");
        write_fixture_file(
            &root.join("crates/allbert-kernel/Cargo.toml"),
            r#"[package]
name = "allbert-kernel"
version = "0.0.0"
edition = "2021"
"#,
        );
        write_fixture_file(
            &root.join("crates/allbert-kernel/src/lib.rs"),
            "pub fn fixture() -> &'static str {\n    \"ok\"\n}\n",
        );
        write_fixture_file(
            &root.join("crates/allbert-cli/Cargo.toml"),
            r#"[package]
name = "allbert-cli"
version = "0.0.0"
edition = "2021"
"#,
        );
        write_fixture_file(
            &root.join("crates/allbert-cli/src/main.rs"),
            "fn main() {\n    println!(\"fixture allbert-cli\");\n}\n",
        );
    }

    fn init_rust_rebuild_fixture_source(temp: &Path) -> PathBuf {
        let root = temp.join("source");
        write_rust_rebuild_fixture_source(&root);
        run_fixture_command(Command::new("git").arg("init").current_dir(&root));
        run_fixture_command(
            Command::new("git")
                .arg("config")
                .arg("user.email")
                .arg("allbert@example.invalid")
                .current_dir(&root),
        );
        run_fixture_command(
            Command::new("git")
                .arg("config")
                .arg("user.name")
                .arg("Allbert Test")
                .current_dir(&root),
        );
        run_fixture_command(Command::new("git").arg("add").arg(".").current_dir(&root));
        run_fixture_command(
            Command::new("git")
                .arg("commit")
                .arg("-m")
                .arg("initial")
                .current_dir(&root),
        );
        root
    }

    fn run_fixture_command(command: &mut Command) {
        let output = command.output().expect("fixture command should spawn");
        assert!(
            output.status.success(),
            "fixture command failed: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn rust_rebuild_fixture_config(source: &Path) -> Config {
        let mut config = Config::default_template();
        config.self_improvement.source_checkout = Some(source.to_path_buf());
        config.self_improvement.worktree_root = PathBuf::from("worktrees");
        config
    }

    #[test]
    fn source_checkout_resolution_prefers_config_then_env_then_executable_walk() {
        let temp = tempfile::tempdir().expect("tempdir");
        let config_root = temp.path().join("config-checkout");
        let env_root = temp.path().join("env-checkout");
        let exe_root = temp.path().join("exe-checkout");
        write_workspace(&config_root, "crates/allbert-kernel", "allbert-kernel");
        write_workspace(&env_root, "crates/allbert-kernel", "allbert-kernel");
        write_workspace(&exe_root, "crates/allbert-kernel", "allbert-kernel");
        let exe_path = exe_root.join("target/debug/allbert-cli");
        write_fixture_file(&exe_path, "");

        let paths = fixture_paths(temp.path());
        let mut config = SelfImprovementConfig {
            source_checkout: Some(config_root.clone()),
            ..SelfImprovementConfig::default()
        };
        let resolved =
            resolve_source_checkout_from(&paths, &config, Some(&env_root), Some(&exe_path))
                .expect("config checkout should resolve");
        assert_eq!(resolved.source, SourceCheckoutSource::Config);
        assert_eq!(
            resolved.path,
            config_root.canonicalize().expect("canonical config root")
        );

        config.source_checkout = None;
        let resolved =
            resolve_source_checkout_from(&paths, &config, Some(&env_root), Some(&exe_path))
                .expect("env checkout should resolve");
        assert_eq!(resolved.source, SourceCheckoutSource::Env);
        assert_eq!(
            resolved.path,
            env_root.canonicalize().expect("canonical env root")
        );

        let resolved = resolve_source_checkout_from(&paths, &config, None, Some(&exe_path))
            .expect("executable walk should resolve");
        assert_eq!(resolved.source, SourceCheckoutSource::ExecutableWalk);
        assert_eq!(
            resolved.path,
            exe_root.canonicalize().expect("canonical exe root")
        );
    }

    #[test]
    fn workspace_detection_accepts_member_path_and_package_identity() {
        let temp = tempfile::tempdir().expect("tempdir");
        let root = temp.path().join("repo");
        write_workspace(&root, "members/kernel", "allbert-kernel");

        let paths = fixture_paths(temp.path());
        let config = SelfImprovementConfig::default();
        let member_path = root.join("members/kernel");
        let resolved = resolve_source_checkout_from(&paths, &config, Some(&member_path), None)
            .expect("member path should walk to workspace root");
        assert_eq!(resolved.path, root.canonicalize().expect("canonical root"));

        write_workspace(&root, "crates/allbert-kernel", "not-the-package-name");
        let resolved = resolve_source_checkout_from(&paths, &config, Some(&root), None)
            .expect("current repo layout should be accepted by member path");
        assert_eq!(resolved.path, root.canonicalize().expect("canonical root"));
    }

    #[test]
    fn missing_source_checkout_returns_operator_readable_refusal() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = fixture_paths(temp.path());
        let config = SelfImprovementConfig::default();
        let err = resolve_source_checkout_from(&paths, &config, None, None)
            .expect_err("missing checkout should fail")
            .to_string();
        assert!(err.contains("self-improvement config set"));
    }

    #[test]
    fn rust_rebuild_ready_requires_pinned_toolchain() {
        let temp = tempfile::tempdir().expect("tempdir");
        let root = temp.path().join("repo");
        write_workspace(&root, "crates/allbert-kernel", "allbert-kernel");
        assert!(!has_pinned_rust_toolchain(&root));
        write_fixture_file(
            &root.join("rust-toolchain.toml"),
            "[toolchain]\nchannel = \"stable\"\n",
        );
        assert!(has_pinned_rust_toolchain(&root));
    }

    #[test]
    fn write_allowlist_allows_worktree_and_denies_profile_source_and_skill() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = fixture_paths(temp.path());
        let source = temp.path().join("source");
        let worktree = temp.path().join(".allbert/worktrees/branch");
        fs::create_dir_all(&worktree).expect("worktree should exist");
        fs::create_dir_all(source.join("skills/rust-rebuild")).expect("skill should exist");

        let allowed = check_self_improvement_write_target(
            &worktree.join("src/lib.rs"),
            &worktree,
            &source,
            &paths,
        )
        .expect("worktree writes should be allowed");
        assert!(allowed.starts_with(&worktree));

        let profile_err = check_self_improvement_write_target(
            &paths.memory.join("MEMORY.md"),
            &worktree,
            &source,
            &paths,
        )
        .expect_err("profile writes should be denied");
        assert!(profile_err.contains("profile path"));

        let source_err = check_self_improvement_write_target(
            &source.join("src/lib.rs"),
            &worktree,
            &source,
            &paths,
        )
        .expect_err("source writes should be denied");
        assert!(source_err.contains("source checkout"));

        let skill_err = check_self_improvement_write_target(
            &source.join("skills/rust-rebuild/SKILL.md"),
            &worktree,
            &source,
            &paths,
        )
        .expect_err("rust-rebuild skill writes should be denied");
        assert!(skill_err.contains("rust-rebuild"));
    }

    #[test]
    fn disk_cap_refuses_new_worktree_when_total_exceeds_limit() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = fixture_paths(temp.path());
        let config = SelfImprovementConfig {
            worktree_root: PathBuf::from("worktrees"),
            max_worktree_gb: 1,
            ..SelfImprovementConfig::default()
        };
        let root = resolve_worktree_root(&paths, &config);
        fs::create_dir_all(root.join("huge")).expect("worktree should exist");
        let file = fs::File::create(root.join("huge/blob.bin")).expect("sparse file");
        file.set_len(BYTES_PER_GIB + 1).expect("sparse len");

        let err = ensure_worktree_creation_allowed(&paths, &config)
            .expect_err("cap should reject projected worktree")
            .to_string();
        assert!(err.contains("worktree disk cap exceeded"));
    }

    #[test]
    fn gc_reclaims_only_marker_stale_worktrees() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = fixture_paths(temp.path());
        let config = SelfImprovementConfig {
            worktree_root: PathBuf::from("worktrees"),
            ..SelfImprovementConfig::default()
        };
        let root = resolve_worktree_root(&paths, &config);
        write_fixture_file(&root.join("active/file.txt"), "active");
        write_fixture_file(&root.join("stale/.allbert-stale"), "");

        let dry = collect_worktree_gc(&paths, &config, true).expect("dry gc");
        assert_eq!(dry.reclaimed_entries, 0);
        assert!(root.join("stale").exists());

        let report = collect_worktree_gc(&paths, &config, false).expect("gc");
        assert_eq!(report.reclaimed_entries, 1);
        assert!(root.join("active").exists());
        assert!(!root.join("stale").exists());
    }

    #[test]
    fn rust_rebuild_creates_isolated_git_worktree_from_fixture_source() {
        let temp = tempfile::tempdir().expect("tempdir");
        let source = init_rust_rebuild_fixture_source(temp.path());
        let paths = fixture_paths(temp.path());
        let config = rust_rebuild_fixture_config(&source);

        let worktree = create_rust_rebuild_worktree(&paths, &config, Some("test patch"))
            .expect("worktree should be created");

        assert!(worktree.path.is_dir());
        assert!(worktree.path.join(".git").exists());
        assert!(worktree.path.join(".allbert-worktree.json").exists());
        assert!(worktree.branch.starts_with("allbert-rebuild-test-patch-"));
        assert_eq!(
            worktree.source_checkout,
            source.canonicalize().expect("canonical source")
        );
    }

    #[test]
    fn rust_rebuild_path_isolation_denies_source_skill_and_allows_worktree() {
        let temp = tempfile::tempdir().expect("tempdir");
        let source = init_rust_rebuild_fixture_source(temp.path());
        write_fixture_file(
            &source.join("skills/rust-rebuild/SKILL.md"),
            "---\nname: rust-rebuild\n",
        );
        let paths = fixture_paths(temp.path());
        let config = rust_rebuild_fixture_config(&source);
        let worktree = create_rust_rebuild_worktree(&paths, &config, Some("isolation"))
            .expect("worktree should be created");

        assert!(check_self_improvement_write_target(
            &worktree.path.join("crates/allbert-kernel/src/lib.rs"),
            &worktree.path,
            &source,
            &paths,
        )
        .is_ok());
        let err = check_self_improvement_write_target(
            &source.join("skills/rust-rebuild/SKILL.md"),
            &worktree.path,
            &source,
            &paths,
        )
        .expect_err("source skill write should be denied");
        assert!(err.contains("rust-rebuild"));
    }

    #[test]
    fn rust_rebuild_tier_a_validation_passes_against_fixture_workspace() {
        let temp = tempfile::tempdir().expect("tempdir");
        let source = init_rust_rebuild_fixture_source(temp.path());
        let paths = fixture_paths(temp.path());
        let config = rust_rebuild_fixture_config(&source);
        let worktree = create_rust_rebuild_worktree(&paths, &config, Some("validation"))
            .expect("worktree should be created");

        let report = run_tier_a_validation(&worktree.path);

        assert_eq!(report.overall, ValidationOverall::SafeToMerge);
        assert_eq!(report.steps.len(), 5);
        assert!(report.steps.iter().all(|step| step.success));
    }

    #[test]
    fn rust_rebuild_patch_artifact_captures_modified_and_new_files() {
        let temp = tempfile::tempdir().expect("tempdir");
        let source = init_rust_rebuild_fixture_source(temp.path());
        let paths = fixture_paths(temp.path());
        let config = rust_rebuild_fixture_config(&source);
        let worktree = create_rust_rebuild_worktree(&paths, &config, Some("artifact"))
            .expect("worktree should be created");
        write_fixture_file(
            &worktree.path.join("crates/allbert-kernel/src/lib.rs"),
            "pub fn fixture() -> &'static str {\n    \"changed\"\n}\n",
        );
        write_fixture_file(&worktree.path.join("NEW.md"), "# New file\n");

        let artifact = emit_patch_artifact(&paths, &worktree.path, "session-1", Some("approval-1"))
            .expect("patch artifact should be emitted");
        let patch = fs::read_to_string(&artifact.path).expect("patch should be readable");

        assert_eq!(artifact.artifact_id, "approval-1");
        assert!(patch.contains("changed"));
        assert!(patch.contains("diff --git a/NEW.md b/NEW.md"));
    }
}
