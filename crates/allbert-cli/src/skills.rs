use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command as StdCommand;

use allbert_kernel::skills::validate_skill_path;
use allbert_kernel::{refresh_agents_markdown, AllbertPaths, Config};
use anyhow::{bail, Context, Result};
use chrono::Utc;
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const INSTALL_METADATA_FILE: &str = ".allbert-install.toml";
const APPROVALS_FILE: &str = "approvals.toml";
const PREVIEW_LINES: usize = 12;

#[derive(Debug)]
pub struct InstallResult {
    pub name: String,
    pub tree_sha256: String,
    pub approval_reused: bool,
    pub installed_path: PathBuf,
}

pub trait SkillPrompter {
    fn confirm_install(&self, preview: &str) -> Result<bool>;
    fn confirm_remove(&self, name: &str) -> Result<bool>;
}

pub struct StdioSkillPrompter;

impl SkillPrompter for StdioSkillPrompter {
    fn confirm_install(&self, preview: &str) -> Result<bool> {
        println!("{preview}");
        prompt_yes_no("Install this skill?", false)
    }

    fn confirm_remove(&self, name: &str) -> Result<bool> {
        prompt_yes_no(
            &format!("Remove installed skill `{name}` from ~/.allbert/skills/installed?"),
            false,
        )
    }
}

pub fn validate_skill(path: &Path) -> Result<String> {
    let report = validate_skill_path(path).map_err(|err| anyhow::anyhow!(err.to_string()))?;
    Ok(format!(
        "valid skill\nname:     {}\npath:     {}\nscripts:  {}\nagents:   {}",
        report.name,
        report.path.display(),
        report.scripts,
        report.agents
    ))
}

pub fn list_installed_skills(paths: &AllbertPaths) -> Result<String> {
    paths.ensure()?;
    let mut skills = Vec::new();
    let mut entries = fs::read_dir(&paths.skills_installed)
        .with_context(|| format!("read {}", paths.skills_installed.display()))?
        .flatten()
        .collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.path());

    for entry in entries {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let skill_path = path.join("SKILL.md");
        if !skill_path.exists() {
            continue;
        }
        let preview = inspect_candidate(&skill_path, "installed")?;
        let metadata = load_install_metadata(&path.join(INSTALL_METADATA_FILE)).ok();
        skills.push(format_skill_summary(&preview, metadata.as_ref()));
    }

    if skills.is_empty() {
        Ok("No installed skills.".into())
    } else {
        Ok(skills.join("\n\n"))
    }
}

pub fn show_installed_skill(paths: &AllbertPaths, name: &str) -> Result<String> {
    paths.ensure()?;
    let root = paths.skills_installed.join(name);
    let skill_path = root.join("SKILL.md");
    if !skill_path.exists() {
        bail!("skill '{}' is not installed", name);
    }
    let preview = inspect_candidate(&skill_path, "installed")?;
    let metadata = load_install_metadata(&root.join(INSTALL_METADATA_FILE)).ok();
    let references = list_relative_files(&root.join("references"), "references")?;
    let assets = list_relative_files(&root.join("assets"), "assets")?;
    let tree_sha = metadata
        .as_ref()
        .map(|metadata| metadata.tree_sha256.as_str())
        .unwrap_or(preview.tree_sha256.as_str());

    let mut lines = Vec::new();
    lines.push(format!("name:           {}", preview.name));
    lines.push(format!("description:    {}", preview.description));
    lines.push(format!("installed path: {}", root.display()));
    lines.push(format!("tree sha256:    {}", tree_sha));
    lines.push(format!(
        "allowed-tools:  {}",
        render_list(&preview.allowed_tools)
    ));
    lines.push(format!("agents:         {}", render_list(&preview.agents)));
    lines.push("scripts:".into());
    if preview.scripts.is_empty() {
        lines.push("  - (none)".into());
    } else {
        for script in &preview.scripts {
            lines.push(format!(
                "  - {} [{}] {} sha256={}",
                script.name, script.interpreter, script.path, script.sha256
            ));
        }
    }
    lines.push("references:".into());
    if references.is_empty() {
        lines.push("  - (none)".into());
    } else {
        for reference in references {
            lines.push(format!("  - {reference}"));
        }
    }
    lines.push("assets:".into());
    if assets.is_empty() {
        lines.push("  - (none)".into());
    } else {
        for asset in assets {
            lines.push(format!("  - {asset}"));
        }
    }
    if let Some(metadata) = metadata {
        lines.push("install metadata:".into());
        lines.push(format!("  source kind: {}", metadata.source.kind));
        lines.push(format!("  source: {}", metadata.source.identity));
        if let Some(reference) = metadata.source.requested_ref {
            lines.push(format!("  requested ref: {}", reference));
        }
        if let Some(commit) = metadata.resolved_commit {
            lines.push(format!("  resolved commit: {}", commit));
        }
        lines.push(format!("  approved at: {}", metadata.approved_at));
        lines.push(format!("  installed at: {}", metadata.installed_at));
    }
    lines.push("SKILL.md excerpt:".into());
    lines.push(indent_block(&preview.excerpt));

    Ok(lines.join("\n"))
}

pub fn install_skill_source_interactive(
    paths: &AllbertPaths,
    config: &Config,
    source: &str,
) -> Result<InstallResult> {
    install_skill_source(paths, config, source, &StdioSkillPrompter)
}

pub fn update_skill_interactive(
    paths: &AllbertPaths,
    config: &Config,
    name: &str,
) -> Result<InstallResult> {
    update_skill(paths, config, name, &StdioSkillPrompter)
}

pub fn install_skill_source<P: SkillPrompter>(
    paths: &AllbertPaths,
    config: &Config,
    source: &str,
    prompter: &P,
) -> Result<InstallResult> {
    let prepared = match parse_install_source(source) {
        SkillInstallSource::LocalPath(path) => PreparedInstall::from_local(&path)?,
        SkillInstallSource::Git(git) => PreparedInstall::from_git(paths, &git)?,
    };
    install_prepared_skill(paths, config, prepared, prompter, false)
}

pub fn update_skill<P: SkillPrompter>(
    paths: &AllbertPaths,
    config: &Config,
    name: &str,
    prompter: &P,
) -> Result<InstallResult> {
    let metadata_path = paths
        .skills_installed
        .join(name)
        .join(INSTALL_METADATA_FILE);
    if !metadata_path.exists() {
        bail!(
            "skill '{}' is not installed or has no install metadata",
            name
        );
    }
    let metadata = load_install_metadata(&metadata_path)?;
    let prepared = match metadata.source.kind.as_str() {
        "local_path" => PreparedInstall::from_local(Path::new(&metadata.source.identity))?,
        "git" => {
            let git = GitInstallSource {
                url: metadata.source.identity.clone(),
                requested_ref: metadata.source.requested_ref.clone(),
            };
            PreparedInstall::from_git(paths, &git)?
        }
        other => bail!("unsupported install source kind '{}'", other),
    };
    install_prepared_skill(paths, config, prepared, prompter, true)
}

pub fn remove_skill_interactive(paths: &AllbertPaths, name: &str) -> Result<()> {
    remove_skill(paths, name, &StdioSkillPrompter)
}

pub fn remove_skill<P: SkillPrompter>(
    paths: &AllbertPaths,
    name: &str,
    prompter: &P,
) -> Result<()> {
    let destination = paths.skills_installed.join(name);
    if !destination.exists() {
        bail!("skill '{}' is not installed", name);
    }
    if !prompter.confirm_remove(name)? {
        bail!("skill removal cancelled");
    }
    fs::remove_dir_all(&destination)
        .with_context(|| format!("remove {}", destination.display()))?;
    refresh_agents_markdown(paths)?;
    Ok(())
}

pub fn init_skill_interactive(name: &str, cwd: &Path) -> Result<PathBuf> {
    let description = prompt_required("Skill description")?;
    let with_scripts = prompt_yes_no("Create an empty scripts/ directory?", false)?;
    let with_references = prompt_yes_no("Create an empty references/ directory?", false)?;
    init_skill_scaffold(cwd, name, &description, with_scripts, with_references)
}

pub fn init_skill_scaffold(
    root: &Path,
    name: &str,
    description: &str,
    with_scripts: bool,
    with_references: bool,
) -> Result<PathBuf> {
    let path = root.join(name);
    if path.exists() {
        bail!("destination already exists: {}", path.display());
    }
    fs::create_dir_all(&path).with_context(|| format!("create {}", path.display()))?;

    let skill_path = path.join("SKILL.md");
    let mut body = String::new();
    body.push_str("---\n");
    body.push_str(&format!("name: {name}\n"));
    body.push_str(&format!("description: {}\n", yaml_quote(description)));
    body.push_str("---\n\n");
    body.push_str(
        "Describe when to use this skill, what it does, and any important constraints.\n",
    );
    fs::write(&skill_path, body).with_context(|| format!("write {}", skill_path.display()))?;

    if with_scripts {
        fs::create_dir_all(path.join("scripts"))
            .with_context(|| format!("create {}", path.join("scripts").display()))?;
    }
    if with_references {
        fs::create_dir_all(path.join("references"))
            .with_context(|| format!("create {}", path.join("references").display()))?;
    }

    validate_skill_path(&skill_path).map_err(|err| anyhow::anyhow!(err.to_string()))?;
    Ok(path)
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct ApprovalStore {
    #[serde(default)]
    approvals: Vec<ApprovalEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ApprovalEntry {
    source: String,
    tree_sha256: String,
    approved_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct InstallMetadata {
    source: SkillSource,
    tree_sha256: String,
    approved_at: String,
    installed_at: String,
    resolved_commit: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SkillSource {
    kind: String,
    identity: String,
    #[serde(default)]
    requested_ref: Option<String>,
}

enum SkillInstallSource {
    LocalPath(PathBuf),
    Git(GitInstallSource),
}

struct GitInstallSource {
    url: String,
    requested_ref: Option<String>,
}

struct PreparedInstall {
    source: SkillSource,
    source_label: String,
    staged_root: PathBuf,
    resolved_commit: Option<String>,
}

impl PreparedInstall {
    fn from_local(source: &Path) -> Result<Self> {
        let source_dir = normalize_source_dir(source)?;
        let source_identity = source_dir
            .canonicalize()
            .with_context(|| format!("canonicalize {}", source_dir.display()))?;
        Ok(Self {
            source: SkillSource {
                kind: "local_path".into(),
                identity: source_identity.display().to_string(),
                requested_ref: None,
            },
            source_label: source_identity.display().to_string(),
            staged_root: source_identity,
            resolved_commit: None,
        })
    }

    fn from_git(paths: &AllbertPaths, source: &GitInstallSource) -> Result<Self> {
        paths.ensure()?;
        let quarantine_dir = paths
            .skills_incoming
            .join(format!("git-fetch-{}", random_suffix()));
        clone_git_source(source, &quarantine_dir)?;
        let staged_root = normalize_cloned_skill_root(&quarantine_dir)?;
        let resolved_commit = git_head_commit(&staged_root)?;
        Ok(Self {
            source: SkillSource {
                kind: "git".into(),
                identity: source.url.clone(),
                requested_ref: source.requested_ref.clone(),
            },
            source_label: match &source.requested_ref {
                Some(reference) => format!("{}#ref={reference}", source.url),
                None => source.url.clone(),
            },
            staged_root,
            resolved_commit: Some(resolved_commit),
        })
    }
}

#[derive(Debug, Clone)]
struct SkillPreview {
    name: String,
    description: String,
    allowed_tools: Vec<String>,
    agents: Vec<String>,
    scripts: Vec<PreviewScript>,
    excerpt: String,
    source_label: String,
    tree_sha256: String,
}

#[derive(Debug, Clone)]
struct PreviewScript {
    name: String,
    path: String,
    interpreter: String,
    sha256: String,
}

#[derive(Debug, Deserialize)]
struct PreviewFrontmatter {
    name: String,
    description: String,
    #[serde(default)]
    scripts: PreviewScripts,
    #[serde(default)]
    agents: PreviewAgents,
    #[serde(rename = "allowed-tools", default)]
    allowed_tools: PreviewAllowedTools,
}

#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
enum PreviewScripts {
    #[default]
    Missing,
    Entries(Vec<PreviewScriptEntry>),
}

#[derive(Debug, Deserialize)]
struct PreviewScriptEntry {
    name: String,
    path: String,
    interpreter: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
enum PreviewAgents {
    #[default]
    Missing,
    Paths(Vec<String>),
    Entries(Vec<PreviewAgentEntry>),
}

#[derive(Debug, Deserialize)]
struct PreviewAgentEntry {
    path: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
enum PreviewAllowedTools {
    #[default]
    Missing,
    String(String),
    List(Vec<String>),
}

impl PreviewScripts {
    fn entries(&self) -> &[PreviewScriptEntry] {
        match self {
            Self::Missing => &[],
            Self::Entries(entries) => entries,
        }
    }
}

impl PreviewAgents {
    fn paths(&self) -> Vec<String> {
        match self {
            Self::Missing => Vec::new(),
            Self::Paths(paths) => paths.clone(),
            Self::Entries(entries) => entries.iter().map(|entry| entry.path.clone()).collect(),
        }
    }
}

impl PreviewAllowedTools {
    fn values(&self) -> Vec<String> {
        match self {
            Self::Missing => Vec::new(),
            Self::String(raw) => raw
                .split_whitespace()
                .map(|value| value.to_string())
                .collect(),
            Self::List(values) => values.clone(),
        }
    }
}

fn parse_install_source(source: &str) -> SkillInstallSource {
    let path = Path::new(source);
    if path.exists() {
        return SkillInstallSource::LocalPath(path.to_path_buf());
    }
    if let Some(rest) = source.strip_prefix("git+") {
        return SkillInstallSource::Git(parse_git_install_source(rest));
    }
    SkillInstallSource::Git(parse_git_install_source(source))
}

fn parse_git_install_source(source: &str) -> GitInstallSource {
    let (url, requested_ref) = match source.split_once("#ref=") {
        Some((url, reference)) => (url.to_string(), Some(reference.to_string())),
        None => (source.to_string(), None),
    };
    GitInstallSource { url, requested_ref }
}

fn normalize_source_dir(source: &Path) -> Result<PathBuf> {
    if source.is_dir() {
        return Ok(source.to_path_buf());
    }
    if source
        .file_name()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value.eq_ignore_ascii_case("SKILL.md"))
    {
        return source
            .parent()
            .map(Path::to_path_buf)
            .ok_or_else(|| anyhow::anyhow!("invalid SKILL.md path"));
    }
    bail!("expected a skill directory or SKILL.md path");
}

fn normalize_cloned_skill_root(root: &Path) -> Result<PathBuf> {
    let skill_path = root.join("SKILL.md");
    if !skill_path.exists() {
        return Ok(root.to_path_buf());
    }

    let raw = fs::read_to_string(&skill_path)
        .with_context(|| format!("read {}", skill_path.display()))?;
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<PreviewFrontmatter>(&raw)
        .map_err(|err| anyhow::anyhow!("parse {}: {err}", skill_path.display()))?;
    let Some(data) = parsed.data else {
        bail!("missing frontmatter in {}", skill_path.display());
    };
    let current_name = root
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| anyhow::anyhow!("invalid cloned skill root {}", root.display()))?;
    if current_name == data.name {
        return Ok(root.to_path_buf());
    }

    let target = root.parent().unwrap().join(&data.name);
    if target.exists() {
        fs::remove_dir_all(&target).with_context(|| format!("remove {}", target.display()))?;
    }
    fs::rename(root, &target)
        .with_context(|| format!("rename {} -> {}", root.display(), target.display()))?;
    Ok(target)
}

fn install_prepared_skill<P: SkillPrompter>(
    paths: &AllbertPaths,
    config: &Config,
    prepared: PreparedInstall,
    prompter: &P,
    replace_existing: bool,
) -> Result<InstallResult> {
    let skill_dir = normalize_source_dir(&prepared.staged_root)?;
    let staged_skill = skill_dir.join("SKILL.md");
    let preview = match inspect_candidate(&staged_skill, &prepared.source_label) {
        Ok(preview) => preview,
        Err(err) => {
            cleanup_prepared_install(&prepared);
            return Err(err);
        }
    };

    let destination = paths.skills_installed.join(&preview.name);
    if destination.exists() && !replace_existing {
        cleanup_prepared_install(&prepared);
        bail!(
            "skill '{}' is already installed at {}",
            preview.name,
            destination.display()
        );
    }

    let mut approvals = load_approvals(&paths.skills.join(APPROVALS_FILE))?;
    let approval_reused = config.install.remember_approvals
        && approvals.approvals.iter().any(|entry| {
            entry.source == prepared.source.identity && entry.tree_sha256 == preview.tree_sha256
        });

    let approved = if approval_reused {
        true
    } else {
        let mut preview_text = render_install_preview(&preview);
        if replace_existing && destination.exists() {
            let existing_metadata =
                load_install_metadata(&destination.join(INSTALL_METADATA_FILE)).ok();
            preview_text.push_str("\n\nUpdate context:\n");
            preview_text.push_str(&format!(
                "existing tree sha256: {}\nnew tree sha256:      {}",
                existing_metadata
                    .as_ref()
                    .map(|value| value.tree_sha256.as_str())
                    .unwrap_or("(unknown)"),
                preview.tree_sha256
            ));
        }
        prompter.confirm_install(&preview_text)?
    };

    if !approved {
        cleanup_prepared_install(&prepared);
        bail!("skill install cancelled");
    }

    let now = Utc::now().to_rfc3339();
    if config.install.remember_approvals && !approval_reused {
        approvals.approvals.push(ApprovalEntry {
            source: prepared.source.identity.clone(),
            tree_sha256: preview.tree_sha256.clone(),
            approved_at: now.clone(),
        });
        persist_approvals(&paths.skills.join(APPROVALS_FILE), &approvals)?;
    }

    if destination.exists() {
        fs::remove_dir_all(&destination)
            .with_context(|| format!("remove {}", destination.display()))?;
    }
    if prepared.source.kind == "local_path" {
        copy_tree(&prepared.staged_root, &destination)?;
    } else if let Err(_err) = fs::rename(&prepared.staged_root, &destination) {
        copy_tree(&prepared.staged_root, &destination)?;
        cleanup_prepared_install(&prepared);
    }

    let metadata = InstallMetadata {
        source: prepared.source,
        tree_sha256: preview.tree_sha256.clone(),
        approved_at: now.clone(),
        installed_at: now,
        resolved_commit: prepared.resolved_commit,
    };
    persist_install_metadata(&destination.join(INSTALL_METADATA_FILE), &metadata)?;
    refresh_agents_markdown(paths)?;

    Ok(InstallResult {
        name: preview.name,
        tree_sha256: preview.tree_sha256,
        approval_reused,
        installed_path: destination,
    })
}

fn cleanup_prepared_install(prepared: &PreparedInstall) {
    if prepared.source.kind == "git" {
        let _ = fs::remove_dir_all(&prepared.staged_root);
    }
}

fn inspect_candidate(skill_path: &Path, source_label: &str) -> Result<SkillPreview> {
    validate_skill_path(skill_path).map_err(|err| anyhow::anyhow!(err.to_string()))?;
    let raw =
        fs::read_to_string(skill_path).with_context(|| format!("read {}", skill_path.display()))?;
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<PreviewFrontmatter>(&raw)
        .map_err(|err| anyhow::anyhow!("parse {}: {err}", skill_path.display()))?;
    let data = parsed
        .data
        .ok_or_else(|| anyhow::anyhow!("missing frontmatter in {}", skill_path.display()))?;
    let skill_dir = skill_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("missing parent for {}", skill_path.display()))?;

    let scripts = data
        .scripts
        .entries()
        .iter()
        .map(|script| {
            let path = skill_dir.join(&script.path);
            let bytes = fs::read(&path).with_context(|| format!("read {}", path.display()))?;
            Ok(PreviewScript {
                name: script.name.clone(),
                path: script.path.clone(),
                interpreter: script.interpreter.clone(),
                sha256: sha256_hex(&bytes),
            })
        })
        .collect::<Result<Vec<_>>>()?;

    Ok(SkillPreview {
        name: data.name,
        description: data.description,
        allowed_tools: data.allowed_tools.values(),
        agents: data.agents.paths(),
        scripts,
        excerpt: first_lines(&raw, PREVIEW_LINES),
        source_label: source_label.into(),
        tree_sha256: hash_tree(skill_dir)?,
    })
}

fn render_install_preview(preview: &SkillPreview) -> String {
    let mut lines = Vec::new();
    lines.push("Skill install preview".to_string());
    lines.push(format!("name:           {}", preview.name));
    lines.push(format!("description:    {}", preview.description));
    lines.push(format!("source:         {}", preview.source_label));
    lines.push(format!("tree sha256:    {}", preview.tree_sha256));
    lines.push(format!(
        "allowed-tools:  {}",
        render_list(&preview.allowed_tools)
    ));
    lines.push(format!("agents:         {}", render_list(&preview.agents)));
    lines.push("scripts:".into());
    if preview.scripts.is_empty() {
        lines.push("  - (none)".into());
    } else {
        for script in &preview.scripts {
            lines.push(format!(
                "  - {} [{}] {} sha256={}",
                script.name, script.interpreter, script.path, script.sha256
            ));
        }
    }
    lines.push("SKILL.md excerpt:".into());
    lines.push(indent_block(&preview.excerpt));
    lines.join("\n")
}

fn format_skill_summary(preview: &SkillPreview, metadata: Option<&InstallMetadata>) -> String {
    let mut lines = Vec::new();
    lines.push(preview.name.to_string());
    lines.push(format!("  description: {}", preview.description));
    lines.push(format!(
        "  allowed-tools: {}",
        render_list(&preview.allowed_tools)
    ));
    lines.push(format!(
        "  scripts: {}  agents: {}",
        preview.scripts.len(),
        preview.agents.len()
    ));
    if let Some(metadata) = metadata {
        lines.push(format!(
            "  source: {} ({})",
            metadata.source.identity, metadata.source.kind
        ));
        if let Some(commit) = &metadata.resolved_commit {
            lines.push(format!("  resolved commit: {}", commit));
        }
    }
    lines.join("\n")
}

fn render_list(values: &[String]) -> String {
    if values.is_empty() {
        "(none)".into()
    } else {
        values.join(", ")
    }
}

fn indent_block(block: &str) -> String {
    block
        .lines()
        .map(|line| format!("  {line}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn first_lines(raw: &str, limit: usize) -> String {
    raw.lines().take(limit).collect::<Vec<_>>().join("\n")
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    format!("{digest:x}")
}

fn hash_tree(root: &Path) -> Result<String> {
    let mut files = Vec::new();
    collect_files(root, root, &mut files)?;
    files.sort_by(|a, b| a.0.cmp(&b.0));

    let mut hasher = Sha256::new();
    for (relative, absolute) in files {
        hasher.update(relative.as_bytes());
        hasher.update([0]);
        hasher.update(fs::read(&absolute).with_context(|| format!("read {}", absolute.display()))?);
        hasher.update([0xff]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn collect_files(root: &Path, current: &Path, out: &mut Vec<(String, PathBuf)>) -> Result<()> {
    let mut entries = fs::read_dir(current)
        .with_context(|| format!("read directory {}", current.display()))?
        .flatten()
        .collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.path());

    for entry in entries {
        let path = entry.path();
        let metadata =
            fs::symlink_metadata(&path).with_context(|| format!("metadata {}", path.display()))?;
        if metadata.file_type().is_symlink() {
            bail!(
                "symlinks are not supported in skill installs: {}",
                path.display()
            );
        }
        if metadata.is_dir() {
            collect_files(root, &path, out)?;
        } else if metadata.is_file() {
            let relative = path
                .strip_prefix(root)
                .expect("file should be under root")
                .to_string_lossy()
                .replace('\\', "/");
            out.push((relative, path));
        }
    }
    Ok(())
}

fn list_relative_files(root: &Path, prefix: &str) -> Result<Vec<String>> {
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut files = Vec::new();
    collect_relative_files(root, root, prefix, &mut files)?;
    files.sort();
    Ok(files)
}

fn collect_relative_files(
    root: &Path,
    current: &Path,
    prefix: &str,
    out: &mut Vec<String>,
) -> Result<()> {
    let mut entries = fs::read_dir(current)
        .with_context(|| format!("read directory {}", current.display()))?
        .flatten()
        .collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.path());

    for entry in entries {
        let path = entry.path();
        let metadata =
            fs::symlink_metadata(&path).with_context(|| format!("metadata {}", path.display()))?;
        if metadata.file_type().is_symlink() {
            bail!(
                "symlinks are not supported in skill installs: {}",
                path.display()
            );
        }
        if metadata.is_dir() {
            collect_relative_files(root, &path, prefix, out)?;
        } else if metadata.is_file() {
            let relative = path
                .strip_prefix(root)
                .expect("path should stay under root")
                .to_string_lossy()
                .replace('\\', "/");
            out.push(format!("{prefix}/{relative}"));
        }
    }
    Ok(())
}

fn copy_tree(source: &Path, destination: &Path) -> Result<()> {
    if !source.is_dir() {
        bail!("expected directory: {}", source.display());
    }
    if destination.exists() {
        fs::remove_dir_all(destination)
            .with_context(|| format!("remove {}", destination.display()))?;
    }
    fs::create_dir_all(destination).with_context(|| format!("create {}", destination.display()))?;
    copy_tree_inner(source, source, destination)
}

fn copy_tree_inner(root: &Path, current: &Path, destination: &Path) -> Result<()> {
    let mut entries = fs::read_dir(current)
        .with_context(|| format!("read directory {}", current.display()))?
        .flatten()
        .collect::<Vec<_>>();
    entries.sort_by_key(|entry| entry.path());

    for entry in entries {
        let path = entry.path();
        let metadata =
            fs::symlink_metadata(&path).with_context(|| format!("metadata {}", path.display()))?;
        if metadata.file_type().is_symlink() {
            bail!(
                "symlinks are not supported in skill installs: {}",
                path.display()
            );
        }
        let relative = path.strip_prefix(root).expect("path should be inside root");
        let target = destination.join(relative);
        if metadata.is_dir() {
            fs::create_dir_all(&target).with_context(|| format!("create {}", target.display()))?;
            copy_tree_inner(root, &path, destination)?;
        } else if metadata.is_file() {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)
                    .with_context(|| format!("create {}", parent.display()))?;
            }
            fs::copy(&path, &target)
                .with_context(|| format!("copy {} -> {}", path.display(), target.display()))?;
        }
    }
    Ok(())
}

fn load_approvals(path: &Path) -> Result<ApprovalStore> {
    if !path.exists() {
        return Ok(ApprovalStore::default());
    }
    let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))
}

fn persist_approvals(path: &Path, store: &ApprovalStore) -> Result<()> {
    let rendered = toml::to_string_pretty(store)?;
    fs::write(path, rendered).with_context(|| format!("write {}", path.display()))
}

fn persist_install_metadata(path: &Path, metadata: &InstallMetadata) -> Result<()> {
    let rendered = toml::to_string_pretty(metadata)?;
    fs::write(path, rendered).with_context(|| format!("write {}", path.display()))
}

fn load_install_metadata(path: &Path) -> Result<InstallMetadata> {
    let raw = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    toml::from_str(&raw).with_context(|| format!("parse {}", path.display()))
}

fn clone_git_source(source: &GitInstallSource, destination: &Path) -> Result<()> {
    if destination.exists() {
        fs::remove_dir_all(destination)
            .with_context(|| format!("remove {}", destination.display()))?;
    }

    let status = StdCommand::new("git")
        .arg("clone")
        .arg(&source.url)
        .arg(destination)
        .status()
        .with_context(|| format!("run git clone for {}", source.url))?;
    if !status.success() {
        bail!("git clone failed for {}", source.url);
    }

    if let Some(reference) = &source.requested_ref {
        let status = StdCommand::new("git")
            .arg("-C")
            .arg(destination)
            .arg("checkout")
            .arg(reference)
            .status()
            .with_context(|| format!("checkout git ref {}", reference))?;
        if !status.success() {
            bail!("git checkout failed for ref {}", reference);
        }
    }
    Ok(())
}

fn git_head_commit(root: &Path) -> Result<String> {
    let output = StdCommand::new("git")
        .arg("-C")
        .arg(root)
        .arg("rev-parse")
        .arg("HEAD")
        .output()
        .with_context(|| format!("read git HEAD for {}", root.display()))?;
    if !output.status.success() {
        bail!("git rev-parse HEAD failed for {}", root.display());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn random_suffix() -> String {
    format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("time should be available")
            .as_nanos()
    )
}

fn yaml_quote(value: &str) -> String {
    format!("{value:?}")
}

fn prompt_yes_no(prompt: &str, default_yes: bool) -> Result<bool> {
    let suffix = if default_yes { "[Y/n]" } else { "[y/N]" };
    print!("{prompt} {suffix} ");
    io::stdout().flush().context("flush stdout")?;
    let mut line = String::new();
    io::stdin().read_line(&mut line).context("read stdin")?;
    let trimmed = line.trim().to_ascii_lowercase();
    if trimmed.is_empty() {
        return Ok(default_yes);
    }
    Ok(matches!(trimmed.as_str(), "y" | "yes"))
}

fn prompt_required(prompt: &str) -> Result<String> {
    loop {
        print!("{prompt}: ");
        io::stdout().flush().context("flush stdout")?;
        let mut line = String::new();
        io::stdin().read_line(&mut line).context("read stdin")?;
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
        eprintln!("Please enter a value.");
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
                "allbert-cli-skills-test-{}-{}-{}",
                std::process::id(),
                counter,
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("time should be available")
                    .as_nanos()
            );
            let path = std::env::temp_dir().join(unique);
            fs::create_dir_all(&path).expect("temp root should be created");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.join("allbert-home"))
        }

        fn source_root(&self) -> PathBuf {
            let root = self.path.join("sources");
            fs::create_dir_all(&root).expect("sources should be created");
            root
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    struct FixedPrompter {
        install_answers: std::sync::Mutex<Vec<bool>>,
        remove_answers: std::sync::Mutex<Vec<bool>>,
        install_calls: std::sync::Mutex<usize>,
    }

    impl FixedPrompter {
        fn new(install_answers: Vec<bool>, remove_answers: Vec<bool>) -> Self {
            Self {
                install_answers: std::sync::Mutex::new(install_answers),
                remove_answers: std::sync::Mutex::new(remove_answers),
                install_calls: std::sync::Mutex::new(0),
            }
        }

        fn install_call_count(&self) -> usize {
            *self.install_calls.lock().unwrap()
        }
    }

    impl SkillPrompter for FixedPrompter {
        fn confirm_install(&self, _preview: &str) -> Result<bool> {
            *self.install_calls.lock().unwrap() += 1;
            Ok(self.install_answers.lock().unwrap().remove(0))
        }

        fn confirm_remove(&self, _name: &str) -> Result<bool> {
            Ok(self.remove_answers.lock().unwrap().remove(0))
        }
    }

    fn write_source_skill(root: &Path, name: &str, body: &str) -> PathBuf {
        let dir = root.join(name);
        fs::create_dir_all(dir.join("scripts")).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            format!(
                "---\nname: {name}\ndescription: Valid test skill\nallowed-tools: [read_reference]\nscripts:\n  - name: helper\n    path: scripts/helper.py\n    interpreter: python\n---\n\n{body}\n"
            ),
        )
        .unwrap();
        fs::write(dir.join("scripts/helper.py"), "print('hello')\n").unwrap();
        dir
    }

    fn git_init_repo(root: &Path) {
        let status = StdCommand::new("git")
            .arg("init")
            .arg(root)
            .status()
            .unwrap();
        assert!(status.success());
        let status = StdCommand::new("git")
            .arg("-C")
            .arg(root)
            .args(["config", "user.name", "Allbert Tests"])
            .status()
            .unwrap();
        assert!(status.success());
        let status = StdCommand::new("git")
            .arg("-C")
            .arg(root)
            .args(["config", "user.email", "allbert-tests@example.invalid"])
            .status()
            .unwrap();
        assert!(status.success());
    }

    fn git_commit_all(root: &Path, message: &str) -> String {
        let status = StdCommand::new("git")
            .arg("-C")
            .arg(root)
            .args(["add", "."])
            .status()
            .unwrap();
        assert!(status.success());
        let status = StdCommand::new("git")
            .arg("-C")
            .arg(root)
            .args(["commit", "-m", message])
            .status()
            .unwrap();
        assert!(status.success());
        git_head_commit(root).unwrap()
    }

    #[test]
    fn install_approve_persists_metadata_and_skill() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let source = write_source_skill(&temp.source_root(), "sample-skill", "Body");
        let config = Config::default_template();
        let prompter = FixedPrompter::new(vec![true], vec![]);

        let result = install_skill_source(
            &paths,
            &config,
            source.to_str().expect("source should be valid utf-8"),
            &prompter,
        )
        .expect("install succeeds");

        assert_eq!(result.name, "sample-skill");
        assert!(!result.approval_reused);
        assert!(result.installed_path.join("SKILL.md").exists());
        assert!(result.installed_path.join(INSTALL_METADATA_FILE).exists());
        assert!(paths.skills.join(APPROVALS_FILE).exists());
        assert_eq!(prompter.install_call_count(), 1);
    }

    #[test]
    fn install_reject_leaves_no_installed_trace() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let source = write_source_skill(&temp.source_root(), "reject-me", "Body");
        let config = Config::default_template();
        let prompter = FixedPrompter::new(vec![false], vec![]);

        let err = install_skill_source(
            &paths,
            &config,
            source.to_str().expect("source should be valid utf-8"),
            &prompter,
        )
        .expect_err("install should be cancelled");
        assert!(err.to_string().contains("cancelled"));
        assert!(!paths.skills_installed.join("reject-me").exists());
        assert!(!paths.skills_incoming.join("reject-me").exists());
    }

    #[test]
    fn install_reprompts_when_tree_sha_changes() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let source = write_source_skill(&temp.source_root(), "mutable-skill", "Body v1");
        let config = Config::default_template();
        let prompter = FixedPrompter::new(vec![true, true], vec![]);

        install_skill_source(
            &paths,
            &config,
            source.to_str().expect("source should be valid utf-8"),
            &prompter,
        )
        .expect("first install works");
        fs::remove_dir_all(paths.skills_installed.join("mutable-skill")).unwrap();
        fs::write(
            source.join("SKILL.md"),
            "---\nname: mutable-skill\ndescription: Valid test skill\nallowed-tools: [read_reference]\nscripts:\n  - name: helper\n    path: scripts/helper.py\n    interpreter: python\n---\n\nBody v2\n",
        )
        .unwrap();

        let result = install_skill_source(
            &paths,
            &config,
            source.to_str().expect("source should be valid utf-8"),
            &prompter,
        )
        .expect("second install works");

        assert!(!result.approval_reused);
        assert_eq!(prompter.install_call_count(), 2);
    }

    #[test]
    fn init_produces_a_skill_that_validates() {
        let temp = TempRoot::new();
        let skill_dir = init_skill_scaffold(&temp.path, "fresh-skill", "A fresh skill", true, true)
            .expect("init should succeed");

        assert!(skill_dir.join("scripts").exists());
        assert!(skill_dir.join("references").exists());
        let rendered = validate_skill(&skill_dir.join("SKILL.md")).expect("skill should validate");
        assert!(rendered.contains("valid skill"));
    }

    #[test]
    fn git_install_and_update_flow_tracks_new_commit() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let repo = write_source_skill(&temp.source_root(), "git-skill", "Body v1");
        git_init_repo(&repo);
        let first_commit = git_commit_all(&repo, "initial");
        let source = format!("file://{}", repo.display());
        let config = Config::default_template();
        let prompter = FixedPrompter::new(vec![true, true], vec![]);

        let installed =
            install_skill_source(&paths, &config, &source, &prompter).expect("git install works");
        let metadata = load_install_metadata(&installed.installed_path.join(INSTALL_METADATA_FILE))
            .expect("metadata should load");
        assert_eq!(
            metadata.resolved_commit.as_deref(),
            Some(first_commit.as_str())
        );

        fs::write(
            repo.join("SKILL.md"),
            "---\nname: git-skill\ndescription: Valid test skill\nallowed-tools: [read_reference]\nscripts:\n  - name: helper\n    path: scripts/helper.py\n    interpreter: python\n---\n\nBody v2\n",
        )
        .unwrap();
        let second_commit = git_commit_all(&repo, "update");

        let updated =
            update_skill(&paths, &config, "git-skill", &prompter).expect("git update works");
        let updated_metadata =
            load_install_metadata(&updated.installed_path.join(INSTALL_METADATA_FILE))
                .expect("updated metadata should load");
        assert_eq!(
            updated_metadata.resolved_commit.as_deref(),
            Some(second_commit.as_str())
        );
        assert_ne!(first_commit, second_commit);
        assert_eq!(prompter.install_call_count(), 2);
    }

    #[test]
    fn git_install_honors_pinned_ref() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let repo = write_source_skill(&temp.source_root(), "pinned-skill", "Body v1");
        git_init_repo(&repo);
        let first_commit = git_commit_all(&repo, "initial");
        fs::write(
            repo.join("SKILL.md"),
            "---\nname: pinned-skill\ndescription: Valid test skill\nallowed-tools: [read_reference]\nscripts:\n  - name: helper\n    path: scripts/helper.py\n    interpreter: python\n---\n\nBody v2\n",
        )
        .unwrap();
        let _second_commit = git_commit_all(&repo, "update");

        let source = format!("file://{}#ref={}", repo.display(), first_commit);
        let config = Config::default_template();
        let prompter = FixedPrompter::new(vec![true], vec![]);

        let installed =
            install_skill_source(&paths, &config, &source, &prompter).expect("git install works");
        let metadata = load_install_metadata(&installed.installed_path.join(INSTALL_METADATA_FILE))
            .expect("metadata should load");
        assert_eq!(
            metadata.resolved_commit.as_deref(),
            Some(first_commit.as_str())
        );
    }

    #[test]
    fn list_and_show_installed_skills_render_operator_details() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let source = write_source_skill(&temp.source_root(), "showcase-skill", "Body v1");
        fs::create_dir_all(source.join("references")).unwrap();
        fs::write(
            source.join("references/guide.md"),
            "# Guide\n\nReference content.\n",
        )
        .unwrap();

        let config = Config::default_template();
        let prompter = FixedPrompter::new(vec![true], vec![]);

        install_skill_source(
            &paths,
            &config,
            source.to_str().expect("source should be valid utf-8"),
            &prompter,
        )
        .expect("install should succeed");

        let listing = list_installed_skills(&paths).expect("list should succeed");
        assert!(listing.contains("showcase-skill"));
        assert!(listing.contains("Valid test skill"));
        assert!(listing.contains("scripts: 1"));

        let shown = show_installed_skill(&paths, "showcase-skill").expect("show should succeed");
        assert!(shown.contains("name:           showcase-skill"));
        assert!(shown.contains("scripts/helper.py"));
        assert!(shown.contains("references/guide.md"));
        assert!(shown.contains("source kind: local_path"));
    }

    #[test]
    fn fresh_profile_lists_seeded_memory_curator_skill() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();

        let listing = list_installed_skills(&paths).expect("list should succeed");
        assert!(listing.contains("memory-curator"));

        let shown = show_installed_skill(&paths, "memory-curator").expect("show should succeed");
        assert!(shown.contains("name:           memory-curator"));
        assert!(shown.contains("allowed-tools:"));
        assert!(shown.contains("list_staged_memory"));
        assert!(shown.contains("agents/extract-from-turn.md"));
    }
}
