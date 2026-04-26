use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use crate::config::{Config, PersonalityDigestConfig, Provider};
use crate::error::KernelError;
use crate::paths::AllbertPaths;

pub trait LearningJob {
    fn name(&self) -> &'static str;
    fn describe_corpus(&self, ctx: &LearningJobContext<'_>) -> Result<LearningCorpus, KernelError>;
    fn run(&self, ctx: &LearningJobContext<'_>) -> Result<LearningJobReport, KernelError>;
}

#[derive(Debug, Clone)]
pub struct LearningJobContext<'a> {
    pub paths: &'a AllbertPaths,
    pub config: &'a Config,
    pub accept_output: bool,
    pub consent_hosted_provider: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LearningCorpus {
    pub summary: LearningCorpusSummary,
    pub items: Vec<LearningCorpusItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LearningCorpusSummary {
    pub source_tiers: Vec<String>,
    pub item_count: usize,
    pub byte_count: usize,
    pub max_input_bytes: usize,
    pub output_path: String,
    pub hosted_provider_required: bool,
    pub hosted_provider_consent: bool,
    pub provider: String,
    pub model: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LearningCorpusItem {
    pub tier: String,
    pub source: String,
    pub bytes: usize,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LearningJobReport {
    pub job_name: String,
    pub inputs: serde_json::Value,
    pub execution: serde_json::Value,
    pub resource_cost: serde_json::Value,
    pub output_artifacts: Vec<LearningOutputArtifact>,
    pub staged_candidates: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LearningOutputArtifact {
    pub path: String,
    pub kind: String,
    pub installed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PersonalityDigestPreview {
    pub corpus: LearningCorpusSummary,
    pub target_artifact_path: String,
    pub draft_root: String,
    pub privacy_warning: String,
}

impl PersonalityDigestPreview {
    pub fn render(&self) -> String {
        format!(
            "personality digest preview\nsource tiers: {}\nitems: {}\ninput bytes: {}/{}\nhosted provider upload: {}\nconsent recorded: {}\nprovider/model: {} / {}\ntarget artifact: {}\ndraft root: {}\nprivacy: {}\n\nNo provider call was made and no files were written.",
            if self.corpus.source_tiers.is_empty() {
                "(none)".into()
            } else {
                self.corpus.source_tiers.join(", ")
            },
            self.corpus.item_count,
            self.corpus.byte_count,
            self.corpus.max_input_bytes,
            yes_no(self.corpus.hosted_provider_required),
            yes_no(self.corpus.hosted_provider_consent),
            self.corpus.provider,
            self.corpus.model,
            self.target_artifact_path,
            self.draft_root,
            self.privacy_warning,
        )
    }
}

pub struct PersonalityDigestJob;

impl LearningJob for PersonalityDigestJob {
    fn name(&self) -> &'static str {
        "personality-digest"
    }

    fn describe_corpus(&self, ctx: &LearningJobContext<'_>) -> Result<LearningCorpus, KernelError> {
        build_personality_corpus(ctx.paths, ctx.config)
    }

    fn run(&self, ctx: &LearningJobContext<'_>) -> Result<LearningJobReport, KernelError> {
        run_personality_digest_job(ctx)
    }
}

pub fn preview_personality_digest(
    paths: &AllbertPaths,
    config: &Config,
) -> Result<PersonalityDigestPreview, KernelError> {
    let job = PersonalityDigestJob;
    let ctx = LearningJobContext {
        paths,
        config,
        accept_output: false,
        consent_hosted_provider: false,
    };
    let corpus = job.describe_corpus(&ctx)?;
    Ok(PersonalityDigestPreview {
        corpus: corpus.summary,
        target_artifact_path: resolve_digest_output_path(paths, &config.learning.personality_digest)?
            .to_string_lossy()
            .into_owned(),
        draft_root: paths
            .learning_personality_digest_runs
            .to_string_lossy()
            .into_owned(),
        privacy_warning: "Hosted providers receive the digest corpus only after profile-local consent; preview never uploads.".into(),
    })
}

pub fn run_personality_digest(
    paths: &AllbertPaths,
    config: &Config,
    accept_output: bool,
    consent_hosted_provider: bool,
) -> Result<LearningJobReport, KernelError> {
    let job = PersonalityDigestJob;
    let ctx = LearningJobContext {
        paths,
        config,
        accept_output,
        consent_hosted_provider,
    };
    job.run(&ctx)
}

fn run_personality_digest_job(
    ctx: &LearningJobContext<'_>,
) -> Result<LearningJobReport, KernelError> {
    if !ctx.config.learning.enabled || !ctx.config.learning.personality_digest.enabled {
        return Err(KernelError::InitFailed(
            "learning.personality_digest is disabled; enable it before running the digest".into(),
        ));
    }
    ensure_hosted_consent(ctx)?;
    let start = Instant::now();
    let corpus = build_personality_corpus(ctx.paths, ctx.config)?;
    let run_id = format!(
        "run-{}",
        OffsetDateTime::now_utc()
            .format(&time::macros::format_description!(
                "[year][month][day]T[hour][minute][second]Z"
            ))
            .map_err(|e| KernelError::InitFailed(format!("format run id: {e}")))?
    );
    let run_dir = ctx.paths.learning_personality_digest_runs.join(&run_id);
    fs::create_dir_all(&run_dir)
        .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", run_dir.display())))?;
    let corpus_digest = corpus_digest(&corpus)?;
    let draft = render_personality_digest(&run_id, &corpus_digest, &corpus, None)?;
    atomic_write(
        &run_dir.join("corpus.json"),
        &serde_json::to_vec_pretty(&corpus)
            .map_err(|e| KernelError::InitFailed(format!("serialize corpus: {e}")))?,
    )?;
    atomic_write(&run_dir.join("draft.md"), draft.as_bytes())?;

    let target = resolve_digest_output_path(ctx.paths, &ctx.config.learning.personality_digest)?;
    let mut artifacts = vec![
        LearningOutputArtifact {
            path: run_dir.join("corpus.json").to_string_lossy().into_owned(),
            kind: "json_corpus".into(),
            installed: false,
        },
        LearningOutputArtifact {
            path: run_dir.join("draft.md").to_string_lossy().into_owned(),
            kind: "markdown_draft".into(),
            installed: false,
        },
    ];
    if ctx.accept_output {
        let accepted =
            render_personality_digest(&run_id, &corpus_digest, &corpus, Some(now_rfc3339()?))?;
        atomic_write(&target, accepted.as_bytes())?;
        artifacts.push(LearningOutputArtifact {
            path: target.to_string_lossy().into_owned(),
            kind: "personality_digest".into(),
            installed: true,
        });
    }

    let report = LearningJobReport {
        job_name: PersonalityDigestJob.name().into(),
        inputs: json!({
            "corpus": corpus.summary,
        }),
        execution: json!({
            "provider": "fake-deterministic",
            "model": "personality-digest-v1",
            "accepted_output": ctx.accept_output,
        }),
        resource_cost: json!({
            "estimated_usd": 0.0,
            "compute_wall_seconds": start.elapsed().as_secs_f64(),
        }),
        output_artifacts: artifacts,
        staged_candidates: Vec::new(),
    };
    atomic_write(
        &run_dir.join("report.json"),
        &serde_json::to_vec_pretty(&report)
            .map_err(|e| KernelError::InitFailed(format!("serialize report: {e}")))?,
    )?;
    Ok(report)
}

fn build_personality_corpus(
    paths: &AllbertPaths,
    config: &Config,
) -> Result<LearningCorpus, KernelError> {
    let digest = &config.learning.personality_digest;
    let mut items = Vec::new();
    let mut remaining = digest.max_input_bytes;
    let include_tiers = digest
        .include_tiers
        .iter()
        .map(|tier| tier.as_str())
        .collect::<BTreeSet<_>>();
    if include_tiers.contains("durable") {
        collect_durable_corpus(paths, &mut items, &mut remaining)?;
    }
    if include_tiers.contains("fact") {
        collect_fact_corpus(paths, &mut items, &mut remaining)?;
    }
    if digest.include_episodes || include_tiers.contains("episode") {
        collect_episode_summary_corpus(paths, digest, &mut items, &mut remaining)?;
    }
    let source_tiers = items
        .iter()
        .map(|item| item.tier.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    let byte_count = items.iter().map(|item| item.bytes).sum();
    Ok(LearningCorpus {
        summary: LearningCorpusSummary {
            source_tiers,
            item_count: items.len(),
            byte_count,
            max_input_bytes: digest.max_input_bytes,
            output_path: digest.output_path.clone(),
            hosted_provider_required: hosted_provider_required(config),
            hosted_provider_consent: hosted_consent_recorded(paths)?,
            provider: config.model.provider.label().into(),
            model: config.model.model_id.clone(),
        },
        items,
    })
}

fn collect_durable_corpus(
    paths: &AllbertPaths,
    items: &mut Vec<LearningCorpusItem>,
    remaining: &mut usize,
) -> Result<(), KernelError> {
    for root in [&paths.memory_notes, &paths.memory_daily] {
        for path in markdown_files(root)? {
            let raw = fs::read_to_string(&path)
                .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
            let (_, body) = split_frontmatter(&raw);
            push_corpus_item(paths, items, remaining, "durable", &path, body.trim())?;
        }
    }
    Ok(())
}

fn collect_fact_corpus(
    paths: &AllbertPaths,
    items: &mut Vec<LearningCorpusItem>,
    remaining: &mut usize,
) -> Result<(), KernelError> {
    for path in markdown_files(&paths.memory_notes)? {
        let raw = fs::read_to_string(&path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
        let (frontmatter, _) = split_frontmatter(&raw);
        if frontmatter.is_empty() {
            continue;
        }
        let Ok(value) = serde_yaml::from_str::<serde_json::Value>(frontmatter) else {
            continue;
        };
        let Some(facts) = value.get("facts").and_then(|value| value.as_array()) else {
            continue;
        };
        for fact in facts {
            let subject = fact
                .get("subject")
                .and_then(|value| value.as_str())
                .unwrap_or("");
            let predicate = fact
                .get("predicate")
                .and_then(|value| value.as_str())
                .unwrap_or("");
            let object = fact
                .get("object")
                .and_then(|value| value.as_str())
                .unwrap_or("");
            let rendered = format!("{subject} {predicate} {object}");
            push_corpus_item(paths, items, remaining, "fact", &path, rendered.trim())?;
        }
    }
    Ok(())
}

fn collect_episode_summary_corpus(
    paths: &AllbertPaths,
    config: &PersonalityDigestConfig,
    items: &mut Vec<LearningCorpusItem>,
    remaining: &mut usize,
) -> Result<(), KernelError> {
    if !paths.sessions.exists() {
        return Ok(());
    }
    let cutoff =
        OffsetDateTime::now_utc() - time::Duration::days(i64::from(config.episode_lookback_days));
    let mut added = 0usize;
    for entry in fs::read_dir(&paths.sessions)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", paths.sessions.display())))?
    {
        if added >= config.max_episode_summaries {
            break;
        }
        let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
        let session_dir = entry.path();
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') || !session_dir.is_dir() {
            continue;
        }
        let turns = session_dir.join("turns.md");
        if !turns.exists() {
            continue;
        }
        let modified = fs::metadata(&turns)
            .ok()
            .and_then(|meta| meta.modified().ok())
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .and_then(|duration| {
                OffsetDateTime::from_unix_timestamp(duration.as_secs() as i64).ok()
            })
            .unwrap_or_else(OffsetDateTime::now_utc);
        if modified < cutoff {
            continue;
        }
        let raw = fs::read_to_string(&turns)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", turns.display())))?;
        let user_turns = raw.matches("### user").count();
        let assistant_turns = raw.matches("### assistant").count();
        let text = format!(
            "Recent episode summary: session {} contains {user_turns} user turn(s) and {assistant_turns} assistant turn(s).",
            name.to_string_lossy()
        );
        push_corpus_item(paths, items, remaining, "episode", &turns, &text)?;
        added += 1;
    }
    Ok(())
}

fn push_corpus_item(
    paths: &AllbertPaths,
    items: &mut Vec<LearningCorpusItem>,
    remaining: &mut usize,
    tier: &str,
    path: &Path,
    text: &str,
) -> Result<(), KernelError> {
    let text = text.trim();
    if text.is_empty() || *remaining == 0 {
        return Ok(());
    }
    let clipped = truncate_to_bytes(text, *remaining);
    if clipped.trim().is_empty() {
        return Ok(());
    }
    *remaining = remaining.saturating_sub(clipped.len());
    items.push(LearningCorpusItem {
        tier: tier.into(),
        source: path
            .strip_prefix(&paths.root)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/"),
        bytes: clipped.len(),
        text: clipped,
    });
    Ok(())
}

fn markdown_files(root: &Path) -> Result<Vec<PathBuf>, KernelError> {
    let mut out = Vec::new();
    if !root.exists() {
        return Ok(out);
    }
    collect_markdown_files(root, &mut out)?;
    out.sort();
    Ok(out)
}

fn collect_markdown_files(root: &Path, out: &mut Vec<PathBuf>) -> Result<(), KernelError> {
    for entry in fs::read_dir(root)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", root.display())))?
    {
        let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
        let path = entry.path();
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        if path.is_dir() {
            collect_markdown_files(&path, out)?;
        } else if path.extension().and_then(|value| value.to_str()) == Some("md") {
            out.push(path);
        }
    }
    Ok(())
}

fn render_personality_digest(
    run_id: &str,
    corpus_digest: &str,
    corpus: &LearningCorpus,
    accepted_at: Option<String>,
) -> Result<String, KernelError> {
    let tiers = corpus.summary.source_tiers.join(",");
    let frontmatter = json!({
        "version": 1,
        "kind": "personality_digest",
        "authority": "learned_overlay",
        "generated_by": "allbert/personality-digest",
        "source_run_id": run_id,
        "corpus_digest": corpus_digest,
        "corpus_tiers": corpus.summary.source_tiers,
        "accepted_at": accepted_at,
    });
    let yaml = serde_yaml::to_string(&frontmatter)
        .map_err(|e| KernelError::InitFailed(format!("serialize digest frontmatter: {e}")))?;
    Ok(format!(
        "---\n{}---\n\n# PERSONALITY\n\n## Learned Collaboration Style\n- Prefer concise, concrete collaboration grounded in reviewed memory.\n- Adapt cautiously from approved tiers: {}.\n\n## Stable Interaction Preferences\n- Ask before treating working history as durable preference.\n- Keep operator review in the loop for memory and personality changes.\n\n## Useful Cautions\n- This learned overlay is lower authority than SOUL.md and current user instructions.\n- Do not store raw transcript excerpts or unapproved staged facts here.\n\n## Open Questions\n- Review future digest drafts for net-new preferences before installation.\n",
        yaml,
        if tiers.is_empty() { "none" } else { &tiers }
    ))
}

fn ensure_hosted_consent(ctx: &LearningJobContext<'_>) -> Result<(), KernelError> {
    if !hosted_provider_required(ctx.config) {
        return Ok(());
    }
    if hosted_consent_recorded(ctx.paths)? {
        return Ok(());
    }
    if !ctx.consent_hosted_provider {
        return Err(KernelError::InitFailed(
            "personality digest requires hosted-provider corpus consent before upload".into(),
        ));
    }
    let consent = json!({
        "granted_at": now_rfc3339()?,
        "provider": ctx.config.model.provider.label(),
        "model": ctx.config.model.model_id,
        "purpose": "personality_digest_corpus",
    });
    atomic_write(
        &ctx.paths.learning_personality_digest_consent,
        &serde_json::to_vec_pretty(&consent)
            .map_err(|e| KernelError::InitFailed(format!("serialize consent: {e}")))?,
    )
}

fn hosted_provider_required(config: &Config) -> bool {
    !matches!(config.model.provider, Provider::Ollama)
}

fn hosted_consent_recorded(paths: &AllbertPaths) -> Result<bool, KernelError> {
    Ok(paths.learning_personality_digest_consent.exists())
}

pub fn resolve_digest_output_path(
    paths: &AllbertPaths,
    config: &PersonalityDigestConfig,
) -> Result<PathBuf, KernelError> {
    let path = Path::new(config.output_path.trim());
    let target = paths.root.join(path);
    if !target.starts_with(&paths.root) {
        return Err(KernelError::InitFailed(
            "personality digest output path escapes ALLBERT_HOME".into(),
        ));
    }
    Ok(target)
}

fn corpus_digest(corpus: &LearningCorpus) -> Result<String, KernelError> {
    let rendered = serde_json::to_vec(corpus)
        .map_err(|e| KernelError::InitFailed(format!("serialize corpus digest: {e}")))?;
    let mut hasher = Sha256::new();
    hasher.update(rendered);
    Ok(format!("sha256:{:x}", hasher.finalize()))
}

fn split_frontmatter(raw: &str) -> (&str, &str) {
    if !raw.starts_with("---\n") {
        return ("", raw);
    }
    let remainder = &raw["---\n".len()..];
    let Some(end) = remainder.find("\n---\n") else {
        return ("", raw);
    };
    (&remainder[..end], &remainder[end + "\n---\n".len()..])
}

fn truncate_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.len() <= max_bytes {
        return input.to_string();
    }
    let mut end = 0usize;
    for (idx, ch) in input.char_indices() {
        let next = idx + ch.len_utf8();
        if next > max_bytes {
            break;
        }
        end = next;
    }
    input[..end].to_string()
}

fn now_rfc3339() -> Result<String, KernelError> {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|e| KernelError::InitFailed(format!("format timestamp: {e}")))
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), KernelError> {
    crate::atomic_write(path, bytes)
        .map_err(|e| KernelError::InitFailed(format!("write {}: {e}", path.display())))
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
    use crate::paths::AllbertPaths;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "allbert-learning-test-{}-{}",
                std::process::id(),
                counter
            ));
            fs::create_dir_all(&path).expect("temp root");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.clone())
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn learning_preview_does_not_write_digest_output() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::create_dir_all(paths.memory_notes.join("projects")).unwrap();
        fs::write(
            paths.memory_notes.join("projects/style.md"),
            "# Style\n\nUse concise updates and concrete next steps.\n",
        )
        .unwrap();
        let config = Config::default_template();
        let preview = preview_personality_digest(&paths, &config).unwrap();
        assert!(preview.render().contains("No provider call was made"));
        assert!(!paths.personality.exists());
    }

    #[test]
    fn learning_digest_requires_acceptance_before_personality_install() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::create_dir_all(paths.memory_notes.join("projects")).unwrap();
        fs::write(
            paths.memory_notes.join("projects/style.md"),
            "# Style\n\nUse concise updates and concrete next steps.\n",
        )
        .unwrap();
        let mut config = Config::default_template();
        config.learning.enabled = true;
        config.learning.personality_digest.enabled = true;
        let report = run_personality_digest(&paths, &config, false, false).unwrap();
        assert!(report
            .output_artifacts
            .iter()
            .any(|artifact| artifact.kind == "markdown_draft" && !artifact.installed));
        assert!(!paths.personality.exists());

        let accepted = run_personality_digest(&paths, &config, true, false).unwrap();
        assert!(accepted
            .output_artifacts
            .iter()
            .any(|artifact| artifact.kind == "personality_digest" && artifact.installed));
        let personality = fs::read_to_string(&paths.personality).unwrap();
        assert!(personality.contains("kind: personality_digest"));
        assert!(personality.contains("## Learned Collaboration Style"));
    }

    #[test]
    fn learning_corpus_excludes_staging_and_caps_episode_summaries() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::create_dir_all(paths.memory_notes.join("projects")).unwrap();
        fs::write(
            paths.memory_notes.join("projects/style.md"),
            "# Style\n\nDurable preference only.\n",
        )
        .unwrap();
        fs::write(
            paths.memory_staging.join("pending.md"),
            "---\nkind: learned_fact\n---\n\n# Pending\n\nDo not include me.\n",
        )
        .unwrap();
        let session_dir = paths.sessions.join("recent");
        fs::create_dir_all(&session_dir).unwrap();
        fs::write(
            session_dir.join("turns.md"),
            "# Session recent\n\n- channel: cli\n\n## 2026-04-20T00:00:00Z\n\n### user\n\nraw transcript text\n\n### assistant\n\nraw answer\n",
        )
        .unwrap();
        let mut config = Config::default_template();
        config.learning.personality_digest.max_episode_summaries = 1;
        let corpus = build_personality_corpus(&paths, &config).unwrap();
        assert!(corpus.items.iter().any(|item| item.tier == "durable"));
        assert!(corpus.items.iter().any(|item| item.tier == "episode"));
        assert!(!corpus
            .items
            .iter()
            .any(|item| item.source.contains("staging")));
        assert!(!corpus
            .items
            .iter()
            .any(|item| item.text.contains("raw transcript text")));
    }

    #[test]
    fn learning_hosted_provider_consent_is_recorded() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let mut config = Config::default_template();
        config.model.provider = Provider::Openrouter;
        config.learning.enabled = true;
        config.learning.personality_digest.enabled = true;
        let err = run_personality_digest(&paths, &config, false, false).unwrap_err();
        assert!(err.to_string().contains("hosted-provider corpus consent"));
        run_personality_digest(&paths, &config, false, true).unwrap();
        assert!(paths.learning_personality_digest_consent.exists());
    }
}
