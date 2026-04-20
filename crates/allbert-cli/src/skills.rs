use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

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

pub fn install_local_skill_interactive(
    paths: &AllbertPaths,
    config: &Config,
    source: &Path,
) -> Result<InstallResult> {
    install_local_skill(paths, config, source, &StdioSkillPrompter)
}

pub fn install_local_skill<P: SkillPrompter>(
    paths: &AllbertPaths,
    config: &Config,
    source: &Path,
    prompter: &P,
) -> Result<InstallResult> {
    paths.ensure()?;

    let source_dir = normalize_source_dir(source)?;
    let source_identity = source_dir
        .canonicalize()
        .with_context(|| format!("canonicalize {}", source_dir.display()))?;
    let source_label = source_identity.display().to_string();

    let staged_name = source_identity
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| anyhow::anyhow!("invalid skill directory name"))?
        .to_string();
    let quarantine_dir = paths.skills_incoming.join(&staged_name);
    if quarantine_dir.exists() {
        fs::remove_dir_all(&quarantine_dir)
            .with_context(|| format!("remove {}", quarantine_dir.display()))?;
    }
    copy_tree(&source_identity, &quarantine_dir)?;

    let staged_skill = quarantine_dir.join("SKILL.md");
    let preview = match inspect_candidate(&staged_skill, &source_label) {
        Ok(preview) => preview,
        Err(err) => {
            let _ = fs::remove_dir_all(&quarantine_dir);
            return Err(err);
        }
    };

    let destination = paths.skills_installed.join(&preview.name);
    if destination.exists() {
        let _ = fs::remove_dir_all(&quarantine_dir);
        bail!(
            "skill '{}' is already installed at {}",
            preview.name,
            destination.display()
        );
    }

    let mut approvals = load_approvals(&paths.skills.join(APPROVALS_FILE))?;
    let approval_reused = config.install.remember_approvals
        && approvals
            .approvals
            .iter()
            .any(|entry| entry.source == source_label && entry.tree_sha256 == preview.tree_sha256);

    let approved = if approval_reused {
        true
    } else {
        prompter.confirm_install(&render_install_preview(&preview))?
    };

    if !approved {
        let _ = fs::remove_dir_all(&quarantine_dir);
        bail!("skill install cancelled");
    }

    let now = Utc::now().to_rfc3339();
    if config.install.remember_approvals && !approval_reused {
        approvals.approvals.push(ApprovalEntry {
            source: source_label.clone(),
            tree_sha256: preview.tree_sha256.clone(),
            approved_at: now.clone(),
        });
        persist_approvals(&paths.skills.join(APPROVALS_FILE), &approvals)?;
    }

    if let Err(_err) = fs::rename(&quarantine_dir, &destination) {
        copy_tree(&quarantine_dir, &destination)?;
        fs::remove_dir_all(&quarantine_dir)
            .with_context(|| format!("remove {}", quarantine_dir.display()))?;
    }

    let metadata = InstallMetadata {
        source: SkillSource {
            kind: "local_path".into(),
            identity: source_label,
        },
        tree_sha256: preview.tree_sha256.clone(),
        approved_at: now.clone(),
        installed_at: now,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SkillSource {
    kind: String,
    identity: String,
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

    #[test]
    fn install_approve_persists_metadata_and_skill() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let source = write_source_skill(&temp.source_root(), "sample-skill", "Body");
        let config = Config::default_template();
        let prompter = FixedPrompter::new(vec![true], vec![]);

        let result =
            install_local_skill(&paths, &config, &source, &prompter).expect("install succeeds");

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

        let err = install_local_skill(&paths, &config, &source, &prompter)
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

        install_local_skill(&paths, &config, &source, &prompter).expect("first install works");
        fs::remove_dir_all(paths.skills_installed.join("mutable-skill")).unwrap();
        fs::write(
            source.join("SKILL.md"),
            "---\nname: mutable-skill\ndescription: Valid test skill\nallowed-tools: [read_reference]\nscripts:\n  - name: helper\n    path: scripts/helper.py\n    interpreter: python\n---\n\nBody v2\n",
        )
        .unwrap();

        let result =
            install_local_skill(&paths, &config, &source, &prompter).expect("second install works");

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
}
