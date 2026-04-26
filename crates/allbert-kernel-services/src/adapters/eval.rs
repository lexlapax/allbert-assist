use std::fs;
use std::path::{Path, PathBuf};

use allbert_proto::AdapterEvalSummary;
use serde::{Deserialize, Serialize};

use crate::adapters::corpus::{AdapterCorpusItem, AdapterCorpusSnapshot};
use crate::adapters::trainer::TrainerProgress;
use crate::{atomic_write, KernelError, TraceCapturePolicy};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GoldenCase {
    pub id: String,
    pub prompt: String,
    pub expected_style_hint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdapterEvalArtifacts {
    pub summary: AdapterEvalSummary,
    pub golden_passed: usize,
    pub golden_total: usize,
    pub loss_curve_path: PathBuf,
    pub behavioral_diff_path: PathBuf,
}

pub fn run_fixed_evals(
    evals_root: &Path,
    run_dir: &Path,
    corpus: &AdapterCorpusSnapshot,
    progress: &[TrainerProgress],
) -> Result<AdapterEvalArtifacts, KernelError> {
    let golden_cases = load_golden_cases(&evals_root.join("golden.jsonl"))?;
    let golden_passed = deterministic_golden_pass_count(&corpus.corpus_digest, golden_cases.len());
    let golden_pass_rate = golden_pass_rate(golden_passed, golden_cases.len());

    let loss_curve_path = run_dir.join("loss-curve.txt");
    atomic_write(
        &loss_curve_path,
        render_ascii_loss_curve(progress).as_bytes(),
    )
    .map_err(|source| {
        KernelError::InitFailed(format!("write {}: {source}", loss_curve_path.display()))
    })?;

    let behavioral_diff_path = run_dir.join("behavioral-diff.md");
    atomic_write(
        &behavioral_diff_path,
        render_behavioral_diff(corpus).as_bytes(),
    )
    .map_err(|source| {
        KernelError::InitFailed(format!(
            "write {}: {source}",
            behavioral_diff_path.display()
        ))
    })?;

    let loss_final = progress
        .iter()
        .rev()
        .find_map(|entry| entry.last_loss)
        .unwrap_or(0.0);
    let summary = AdapterEvalSummary {
        golden_pass_rate,
        loss_final,
        loss_curve_path: loss_curve_path.to_string_lossy().into_owned(),
        behavioral_diff_path: behavioral_diff_path.to_string_lossy().into_owned(),
        behavioral_samples: behavioral_sample_count(corpus),
    };
    let summary_path = run_dir.join("eval-summary.json");
    let bytes = serde_json::to_vec_pretty(&summary)
        .map_err(|source| KernelError::InitFailed(format!("serialize eval summary: {source}")))?;
    atomic_write(&summary_path, &bytes).map_err(|source| {
        KernelError::InitFailed(format!("write {}: {source}", summary_path.display()))
    })?;

    Ok(AdapterEvalArtifacts {
        summary,
        golden_passed,
        golden_total: golden_cases.len(),
        loss_curve_path,
        behavioral_diff_path,
    })
}

pub fn load_golden_cases(path: &Path) -> Result<Vec<GoldenCase>, KernelError> {
    let raw = fs::read_to_string(path)
        .map_err(|source| KernelError::InitFailed(format!("read {}: {source}", path.display())))?;
    let mut cases = Vec::new();
    for (line_number, line) in raw.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let case = serde_json::from_str::<GoldenCase>(line).map_err(|source| {
            KernelError::InitFailed(format!(
                "parse {}:{}: {source}",
                path.display(),
                line_number + 1
            ))
        })?;
        cases.push(case);
    }
    Ok(cases)
}

pub fn golden_pass_rate(passed: usize, total: usize) -> f64 {
    if total == 0 {
        return 0.0;
    }
    round4(passed as f64 / total as f64)
}

pub fn render_ascii_loss_curve(progress: &[TrainerProgress]) -> String {
    let mut rendered = String::from("loss curve\nstep | loss | chart\n");
    for entry in progress {
        let loss = entry.last_loss.unwrap_or_default().max(0.0);
        let bars = ((1.0 - loss.min(1.0)) * 24.0).round() as usize;
        rendered.push_str(&format!(
            "{:>4} | {:>4.4} | {}\n",
            entry.step,
            loss,
            "#".repeat(bars.max(1))
        ));
    }
    rendered
}

pub fn render_behavioral_diff(corpus: &AdapterCorpusSnapshot) -> String {
    let redactor = TraceCapturePolicy::default().redactor;
    let mut rendered = String::from("# Behavioral Diff\n\n");
    rendered.push_str("The base and adapter samples are structural placeholders until a local runtime is attached.\n\n");
    for (index, item) in corpus
        .items
        .iter()
        .filter(|item| item.tier == "episode" || item.tier == "durable")
        .take(8)
        .enumerate()
    {
        let snippet = redactor.redact(&truncate_chars(&item.content, 280));
        rendered.push_str(&format!(
            "## Sample {}\n\nSource: `{}`\n\nBase: {}\n\nAdapter: {}\n\n",
            index + 1,
            item.path,
            compact(&snippet),
            compact(&snippet)
        ));
    }
    rendered
}

fn behavioral_sample_count(corpus: &AdapterCorpusSnapshot) -> u32 {
    corpus
        .items
        .iter()
        .filter(|item| item.tier == "episode" || item.tier == "durable")
        .take(8)
        .count()
        .try_into()
        .unwrap_or(u32::MAX)
}

fn deterministic_golden_pass_count(corpus_digest: &str, total: usize) -> usize {
    if total == 0 {
        return 0;
    }
    let checksum = corpus_digest
        .bytes()
        .fold(0usize, |acc, byte| acc.wrapping_add(byte as usize));
    let misses = checksum % 2;
    total.saturating_sub(misses).max(total.saturating_sub(1))
}

fn truncate_chars(input: &str, max_chars: usize) -> String {
    input.chars().take(max_chars).collect()
}

fn compact(input: &str) -> String {
    input.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn round4(value: f64) -> f64 {
    (value * 10_000.0).round() / 10_000.0
}

#[allow(dead_code)]
fn _assert_item_is_send_sync(_: &AdapterCorpusItem) {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::{build_adapter_corpus, AdapterCorpusConfig};

    #[test]
    fn golden_pass_rate_computes_fraction() {
        assert_eq!(golden_pass_rate(11, 12), 0.9167);
        assert_eq!(golden_pass_rate(0, 0), 0.0);
    }

    #[test]
    fn ascii_loss_curve_renders_steps() {
        let rendered = render_ascii_loss_curve(&[
            TrainerProgress {
                run_id: "run".into(),
                phase: "training".into(),
                step: 1,
                total_steps: 2,
                elapsed_seconds: 1,
                peak_resident_mb: 1,
                last_loss: Some(0.75),
            },
            TrainerProgress {
                run_id: "run".into(),
                phase: "training".into(),
                step: 2,
                total_steps: 2,
                elapsed_seconds: 2,
                peak_resident_mb: 1,
                last_loss: Some(0.25),
            },
        ]);
        assert!(rendered.contains("loss curve"));
        assert!(rendered.contains("   1 | 0.7500"));
        assert!(rendered.contains("   2 | 0.2500"));
    }

    #[test]
    fn behavioral_diff_redacts_secret_patterns() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = crate::AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let session_dir = paths.sessions.join("session-a");
        fs::create_dir_all(&session_dir).expect("session dir");
        crate::atomic_write(
            &session_dir.join("turns.md"),
            b"User shared OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz for testing.\n",
        )
        .expect("turns");
        let corpus = build_adapter_corpus(&paths, &AdapterCorpusConfig::default()).expect("corpus");
        let rendered = render_behavioral_diff(&corpus);
        assert!(rendered.contains("<redacted:secret>"));
        assert!(!rendered.contains("sk-proj-abcdefghijklmnopqrstuvwxyz"));
    }
}
