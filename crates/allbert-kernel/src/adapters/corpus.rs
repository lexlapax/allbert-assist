use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{AllbertPaths, KernelError, TraceCapturePolicy};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterCorpusConfig {
    pub max_input_bytes: usize,
    pub max_episode_summaries: usize,
    pub max_trace_bytes_per_session: usize,
    pub capture_traces: bool,
    pub include_tiers: Vec<String>,
    pub include_episodes: bool,
}

impl Default for AdapterCorpusConfig {
    fn default() -> Self {
        Self {
            max_input_bytes: 512 * 1024,
            max_episode_summaries: 64,
            max_trace_bytes_per_session: 64 * 1024,
            capture_traces: false,
            include_tiers: vec!["durable".into(), "fact".into()],
            include_episodes: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterCorpusItem {
    pub tier: String,
    pub source: String,
    pub path: String,
    pub bytes: usize,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterCorpusSnapshot {
    pub corpus_digest: String,
    pub total_bytes: usize,
    pub items: Vec<AdapterCorpusItem>,
}

pub fn build_adapter_corpus(
    paths: &AllbertPaths,
    config: &AdapterCorpusConfig,
) -> Result<AdapterCorpusSnapshot, KernelError> {
    let mut builder = CorpusBuilder::new(paths, config);
    builder.add_file("soul", "bootstrap", &paths.soul)?;
    builder.add_file("personality", "personality", &paths.personality)?;
    builder.add_durable_memory()?;
    if config.include_episodes {
        builder.add_episode_summaries()?;
    }
    if config.capture_traces {
        builder.add_trace_excerpts()?;
    }
    Ok(builder.finish())
}

struct CorpusBuilder<'a> {
    paths: &'a AllbertPaths,
    config: &'a AdapterCorpusConfig,
    items: Vec<AdapterCorpusItem>,
    total_bytes: usize,
}

impl<'a> CorpusBuilder<'a> {
    fn new(paths: &'a AllbertPaths, config: &'a AdapterCorpusConfig) -> Self {
        Self {
            paths,
            config,
            items: Vec::new(),
            total_bytes: 0,
        }
    }

    fn add_file(&mut self, tier: &str, source: &str, path: &Path) -> Result<(), KernelError> {
        if !path.exists() {
            return Ok(());
        }
        let content = read_text(path)?;
        self.push_item(tier, source, path, content);
        Ok(())
    }

    fn add_durable_memory(&mut self) -> Result<(), KernelError> {
        if !self.paths.memory_notes.exists() {
            return Ok(());
        }
        let include_durable = self
            .config
            .include_tiers
            .iter()
            .any(|tier| tier == "durable");
        let include_fact = self.config.include_tiers.iter().any(|tier| tier == "fact");
        for path in markdown_files(&self.paths.memory_notes)? {
            let content = read_text(&path)?;
            if include_fact {
                for fact in extract_fact_items(&content) {
                    self.push_item("fact", "memory-frontmatter", &path, fact);
                }
            }
            if include_durable {
                self.push_item("durable", "memory-note", &path, content);
            }
        }
        Ok(())
    }

    fn add_episode_summaries(&mut self) -> Result<(), KernelError> {
        if !self.paths.sessions.exists() {
            return Ok(());
        }
        let mut added = 0usize;
        for session_dir in session_dirs(&self.paths.sessions)? {
            if added >= self.config.max_episode_summaries {
                break;
            }
            let turns = session_dir.join("turns.md");
            if turns.exists() {
                self.push_item("episode", "session-turns", &turns, read_text(&turns)?);
                added += 1;
            }
        }
        Ok(())
    }

    fn add_trace_excerpts(&mut self) -> Result<(), KernelError> {
        if !self.paths.sessions.exists() {
            return Ok(());
        }
        let redactor = TraceCapturePolicy::default().redactor;
        for session_dir in session_dirs(&self.paths.sessions)? {
            let trace = session_dir.join("trace.jsonl");
            if trace.exists() {
                let content = read_text_limited(&trace, self.config.max_trace_bytes_per_session)?;
                self.push_item("trace", "session-trace", &trace, redactor.redact(&content));
            }
        }
        Ok(())
    }

    fn push_item(&mut self, tier: &str, source: &str, path: &Path, content: String) {
        if content.trim().is_empty() || self.total_bytes >= self.config.max_input_bytes {
            return;
        }
        let remaining = self.config.max_input_bytes - self.total_bytes;
        let content = truncate_to_bytes(&content, remaining);
        let bytes = content.len();
        if bytes == 0 {
            return;
        }
        self.total_bytes += bytes;
        self.items.push(AdapterCorpusItem {
            tier: tier.into(),
            source: source.into(),
            path: normalized_path(self.paths, path),
            bytes,
            content,
        });
    }

    fn finish(mut self) -> AdapterCorpusSnapshot {
        self.items.sort_by(|left, right| {
            left.tier
                .cmp(&right.tier)
                .then_with(|| left.path.cmp(&right.path))
                .then_with(|| left.source.cmp(&right.source))
        });
        let mut canonical = String::new();
        for item in &self.items {
            canonical.push_str("---allbert-corpus-item---\n");
            canonical.push_str("tier: ");
            canonical.push_str(&item.tier);
            canonical.push('\n');
            canonical.push_str("source: ");
            canonical.push_str(&item.source);
            canonical.push('\n');
            canonical.push_str("path: ");
            canonical.push_str(&item.path);
            canonical.push('\n');
            canonical.push_str("bytes: ");
            canonical.push_str(&item.bytes.to_string());
            canonical.push_str("\n\n");
            canonical.push_str(&item.content);
            canonical.push('\n');
        }
        let digest = Sha256::digest(canonical.as_bytes());
        AdapterCorpusSnapshot {
            corpus_digest: format!("sha256:{digest:x}"),
            total_bytes: self.total_bytes,
            items: self.items,
        }
    }
}

fn markdown_files(root: &Path) -> Result<Vec<PathBuf>, KernelError> {
    let mut files = Vec::new();
    collect_markdown_files(root, &mut files)?;
    files.sort();
    Ok(files)
}

fn collect_markdown_files(path: &Path, files: &mut Vec<PathBuf>) -> Result<(), KernelError> {
    for entry in sorted_entries(path)? {
        let path = entry.path();
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        let file_type = entry.file_type().map_err(|source| {
            corpus_error(format!("read corpus path {}: {source}", path.display()))
        })?;
        if file_type.is_dir() {
            collect_markdown_files(&path, files)?;
        } else if path.extension().is_some_and(|ext| ext == "md") {
            files.push(path);
        }
    }
    Ok(())
}

fn session_dirs(root: &Path) -> Result<Vec<PathBuf>, KernelError> {
    let mut dirs = Vec::new();
    for entry in sorted_entries(root)? {
        let path = entry.path();
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        if entry
            .file_type()
            .map_err(|source| {
                corpus_error(format!("read session path {}: {source}", path.display()))
            })?
            .is_dir()
        {
            dirs.push(path);
        }
    }
    dirs.sort();
    Ok(dirs)
}

fn extract_fact_items(content: &str) -> Vec<String> {
    let Some(frontmatter) = yaml_frontmatter(content) else {
        return Vec::new();
    };
    let Ok(value) = serde_yaml::from_str::<serde_yaml::Value>(frontmatter) else {
        return Vec::new();
    };
    let Some(facts) = value.get("facts").and_then(|value| value.as_sequence()) else {
        return Vec::new();
    };
    facts
        .iter()
        .filter_map(|fact| serde_json::to_string(fact).ok())
        .collect()
}

fn yaml_frontmatter(content: &str) -> Option<&str> {
    let rest = content.strip_prefix("---\n")?;
    let end = rest.find("\n---")?;
    Some(&rest[..end])
}

fn sorted_entries(path: &Path) -> Result<Vec<fs::DirEntry>, KernelError> {
    let mut entries = fs::read_dir(path)
        .map_err(|source| corpus_error(format!("read dir {}: {source}", path.display())))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| corpus_error(format!("read dir {}: {source}", path.display())))?;
    entries.sort_by_key(|entry| entry.path());
    Ok(entries)
}

fn read_text(path: &Path) -> Result<String, KernelError> {
    let bytes = fs::read(path)
        .map_err(|source| corpus_error(format!("read corpus file {}: {source}", path.display())))?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn read_text_limited(path: &Path, max_bytes: usize) -> Result<String, KernelError> {
    let text = read_text(path)?;
    Ok(truncate_to_bytes(&text, max_bytes))
}

fn truncate_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.len() <= max_bytes {
        return input.to_string();
    }
    let mut end = max_bytes;
    while !input.is_char_boundary(end) {
        end -= 1;
    }
    input[..end].to_string()
}

fn normalized_path(paths: &AllbertPaths, path: &Path) -> String {
    path.strip_prefix(&paths.root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

fn corpus_error(message: impl Into<String>) -> KernelError {
    KernelError::Request(message.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::atomic_write;

    #[test]
    fn corpus_digest_is_deterministic_and_changes_for_persona_inputs() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        atomic_write(&paths.soul, b"# SOUL\n\nBe concrete.\n").expect("soul");
        atomic_write(&paths.personality, b"# PERSONALITY\n\nUse short updates.\n")
            .expect("personality");
        let note = paths.memory_notes.join("project.md");
        atomic_write(
            &note,
            b"---\nfacts:\n  - subject: user\n    predicate: prefers\n    object: concise updates\n---\n# Project\n\nDurable note.\n",
        )
        .expect("note");
        let session_dir = paths.sessions.join("session-a");
        fs::create_dir_all(&session_dir).expect("session dir");
        atomic_write(
            &session_dir.join("turns.md"),
            b"# Turns\n\nUser asked for concrete next steps.\n",
        )
        .expect("turns");

        let config = AdapterCorpusConfig::default();
        let first = build_adapter_corpus(&paths, &config).expect("first");
        let second = build_adapter_corpus(&paths, &config).expect("second");
        assert_eq!(first.corpus_digest, second.corpus_digest);
        assert!(first.items.iter().any(|item| item.tier == "fact"));
        assert!(first.items.iter().any(|item| item.tier == "episode"));

        atomic_write(&paths.personality, b"# PERSONALITY\n\nUse more detail.\n")
            .expect("personality changed");
        let changed = build_adapter_corpus(&paths, &config).expect("changed");
        assert_ne!(first.corpus_digest, changed.corpus_digest);

        atomic_write(&paths.soul, b"# SOUL\n\nBe expansive.\n").expect("soul changed");
        let changed_again = build_adapter_corpus(&paths, &config).expect("changed again");
        assert_ne!(changed.corpus_digest, changed_again.corpus_digest);
    }

    #[test]
    fn trace_opt_in_changes_digest_and_redacts_secret_patterns() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let session_dir = paths.sessions.join("session-a");
        fs::create_dir_all(&session_dir).expect("session dir");
        atomic_write(
            &session_dir.join("trace.jsonl"),
            b"{\"event\":\"tool\",\"api_key\":\"sk-proj-abcdefghijklmnopqrstuvwxyz\"}\n",
        )
        .expect("trace");

        let without_trace =
            build_adapter_corpus(&paths, &AdapterCorpusConfig::default()).expect("without");
        let with_trace = build_adapter_corpus(
            &paths,
            &AdapterCorpusConfig {
                capture_traces: true,
                ..AdapterCorpusConfig::default()
            },
        )
        .expect("with trace");

        assert_ne!(without_trace.corpus_digest, with_trace.corpus_digest);
        let trace_item = with_trace
            .items
            .iter()
            .find(|item| item.tier == "trace")
            .expect("trace item");
        assert!(trace_item.content.contains("<redacted:secret>"));
        assert!(!trace_item
            .content
            .contains("sk-proj-abcdefghijklmnopqrstuvwxyz"));
    }
}
