use std::collections::HashSet;
use std::path::PathBuf;
use std::process::Child;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};

use allbert_proto::{
    AdapterHyperparameters, AdapterManifest, AdapterTrainingProgressPayload, BaseModelRef,
};

use crate::adapters::corpus::AdapterCorpusSnapshot;
use crate::security::{exec_policy, NormalizedExec, PolicyDecision};
use crate::{AllbertPaths, Config};

pub const TRAINER_STDIO_CAPTURE_BYTES: usize = 64 * 1024;
pub const TRAINER_TRUNCATION_MARKER: &str = "\n<truncated:trainer-output>\n";

pub type TrainerProgressCallback =
    Arc<dyn Fn(&TrainerProgress) -> Result<(), TrainerError> + Send + Sync>;

pub trait AdapterTrainer: Send + Sync {
    fn backend_id(&self) -> &'static str;

    fn train(
        &self,
        plan: &TrainingPlan,
        hooks: &TrainerHooks,
        cancel: &CancellationToken,
    ) -> Result<TrainingOutcome, TrainerError>;
}

#[derive(Debug, Clone)]
pub struct TrainingPlan {
    pub run_id: String,
    pub run_dir: PathBuf,
    pub trainer_backend: String,
    pub base_model: BaseModelRef,
    pub corpus: AdapterCorpusSnapshot,
    pub hyperparameters: AdapterHyperparameters,
    pub compute_used_today_seconds: u64,
    pub compute_cap_wall_seconds: Option<u64>,
    pub total_steps: u32,
    pub estimated_peak_resident_mb: u64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct TrainerProgress {
    pub run_id: String,
    pub phase: String,
    pub step: u32,
    pub total_steps: u32,
    pub elapsed_seconds: u64,
    pub peak_resident_mb: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_loss: Option<f64>,
}

impl From<&TrainerProgress> for AdapterTrainingProgressPayload {
    fn from(progress: &TrainerProgress) -> Self {
        Self {
            run_id: progress.run_id.clone(),
            phase: progress.phase.clone(),
            step: progress.step,
            total_steps: progress.total_steps,
            elapsed_seconds: progress.elapsed_seconds,
            eta_seconds: None,
            peak_resident_mb: progress.peak_resident_mb,
            last_loss: progress.last_loss,
        }
    }
}

#[derive(Debug, Clone)]
pub struct TrainingOutcome {
    pub manifest: AdapterManifest,
    pub run_dir: PathBuf,
    pub weights_path: PathBuf,
    pub loss_curve_path: PathBuf,
    pub eval_summary_path: PathBuf,
    pub progress: Vec<TrainerProgress>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrainerCommand {
    pub program: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
}

impl TrainerCommand {
    pub fn normalized_exec(&self) -> NormalizedExec {
        NormalizedExec {
            program: self.program.clone(),
            args: self.args.clone(),
            cwd: self.cwd.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapturedTrainerOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub stdout_truncated: bool,
    pub stderr_truncated: bool,
}

pub fn minimal_trainer_env(paths: &AllbertPaths) -> Vec<(String, String)> {
    [
        ("PATH", std::env::var("PATH").unwrap_or_default()),
        ("HOME", std::env::var("HOME").unwrap_or_default()),
        (
            "TMPDIR",
            std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".into()),
        ),
        ("ALLBERT_HOME", paths.root.to_string_lossy().into_owned()),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_string(), value))
    .collect()
}

pub fn capture_trainer_output(
    stdout: &[u8],
    stderr: &[u8],
    cap_bytes: usize,
) -> CapturedTrainerOutput {
    let (stdout, stdout_truncated) = truncate_output(stdout, cap_bytes);
    let (stderr, stderr_truncated) = truncate_output(stderr, cap_bytes);
    CapturedTrainerOutput {
        stdout,
        stderr,
        stdout_truncated,
        stderr_truncated,
    }
}

pub fn ensure_trainer_allowed(
    config: &Config,
    backend: &str,
    command: &TrainerCommand,
) -> Result<(), TrainerError> {
    let backend_allowed = config
        .learning
        .adapter_training
        .allowed_backends
        .iter()
        .any(|allowed| allowed == backend);
    if !backend_allowed {
        return Err(TrainerError::Backend(format!(
            "trainer backend `{backend}` is not allowed; add it to learning.adapter_training.allowed_backends and add `{}` to security.exec_allow",
            command.program
        )));
    }
    let approved_session_execs = HashSet::new();
    match exec_policy(
        &command.normalized_exec(),
        &config.security,
        &approved_session_execs,
    ) {
        PolicyDecision::AutoAllow => Ok(()),
        PolicyDecision::NeedsConfirm(_) => Err(TrainerError::Backend(format!(
            "trainer command `{}` is not auto-allowed; add backend `{backend}` to learning.adapter_training.allowed_backends and add `{}` to security.exec_allow",
            command.program, command.program
        ))),
        PolicyDecision::Deny(reason) => Err(TrainerError::Backend(format!(
            "trainer command `{}` is denied ({reason}); backend `{backend}` must be listed in learning.adapter_training.allowed_backends and the binary must pass security.exec_allow/security.exec_deny",
            command.program
        ))),
    }
}

#[derive(Clone, Default)]
pub struct TrainerHooks {
    on_progress: Option<TrainerProgressCallback>,
}

impl TrainerHooks {
    pub fn new() -> Self {
        Self { on_progress: None }
    }

    pub fn with_progress_callback(callback: TrainerProgressCallback) -> Self {
        Self {
            on_progress: Some(callback),
        }
    }

    pub fn check_dispatch(&self, plan: &TrainingPlan) -> Result<(), TrainerError> {
        if let Some(cap) = plan.compute_cap_wall_seconds {
            if plan.compute_used_today_seconds >= cap {
                return Err(TrainerError::ComputeCapExceeded {
                    cap_wall_seconds: cap,
                    used_wall_seconds: plan.compute_used_today_seconds,
                    attempted_wall_seconds: 0,
                });
            }
        }
        Ok(())
    }

    pub fn record_progress(
        &self,
        plan: &TrainingPlan,
        progress: &TrainerProgress,
    ) -> Result<(), TrainerError> {
        if let Some(cap) = plan.compute_cap_wall_seconds {
            let attempted = plan
                .compute_used_today_seconds
                .saturating_add(progress.elapsed_seconds);
            if attempted > cap {
                return Err(TrainerError::ComputeCapExceeded {
                    cap_wall_seconds: cap,
                    used_wall_seconds: plan.compute_used_today_seconds,
                    attempted_wall_seconds: attempted,
                });
            }
        }
        if let Some(callback) = &self.on_progress {
            callback(progress)?;
        }
        Ok(())
    }
}

fn truncate_output(bytes: &[u8], cap_bytes: usize) -> (Vec<u8>, bool) {
    if bytes.len() <= cap_bytes {
        return (bytes.to_vec(), false);
    }
    let marker = TRAINER_TRUNCATION_MARKER.as_bytes();
    let keep = cap_bytes.saturating_sub(marker.len());
    let mut truncated = bytes[..keep.min(bytes.len())].to_vec();
    truncated.extend_from_slice(marker);
    (truncated, true)
}

#[derive(Debug, Clone, Default)]
pub struct CancellationToken {
    inner: Arc<AtomicBool>,
}

impl CancellationToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.inner.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.load(Ordering::SeqCst)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum TrainerError {
    #[error("adapter training cancelled for run {run_id}")]
    Cancelled { run_id: String },
    #[error(
        "adapter training compute cap exceeded: cap={cap_wall_seconds}s used={used_wall_seconds}s attempted={attempted_wall_seconds}s"
    )]
    ComputeCapExceeded {
        cap_wall_seconds: u64,
        used_wall_seconds: u64,
        attempted_wall_seconds: u64,
    },
    #[error("invalid adapter training plan: {0}")]
    InvalidPlan(String),
    #[error("adapter trainer backend error: {0}")]
    Backend(String),
    #[error("adapter trainer I/O error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

impl TrainerError {
    pub fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        Self::Io {
            path: path.into(),
            source,
        }
    }
}

pub fn terminate_child_with_grace(child: &mut Child, grace: Duration) -> Result<(), TrainerError> {
    if child
        .try_wait()
        .map_err(|source| TrainerError::Io {
            path: format!("pid:{}", child.id()).into(),
            source,
        })?
        .is_some()
    {
        return Ok(());
    }

    #[cfg(unix)]
    {
        let pid = child.id() as libc::pid_t;
        // SAFETY: pid comes from std::process::Child for this process tree. kill only sends a signal.
        let rc = unsafe { libc::kill(pid, libc::SIGTERM) };
        if rc != 0 {
            return Err(TrainerError::Backend(format!(
                "send SIGTERM to trainer pid {} failed: {}",
                child.id(),
                std::io::Error::last_os_error()
            )));
        }
    }
    #[cfg(not(unix))]
    {
        child.kill().map_err(|source| TrainerError::Io {
            path: format!("pid:{}", child.id()).into(),
            source,
        })?;
    }

    let started = Instant::now();
    while started.elapsed() < grace {
        if child
            .try_wait()
            .map_err(|source| TrainerError::Io {
                path: format!("pid:{}", child.id()).into(),
                source,
            })?
            .is_some()
        {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    child.kill().map_err(|source| TrainerError::Io {
        path: format!("pid:{}", child.id()).into(),
        source,
    })?;
    child.wait().map_err(|source| TrainerError::Io {
        path: format!("pid:{}", child.id()).into(),
        source,
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Config;

    fn command() -> TrainerCommand {
        TrainerCommand {
            program: "/usr/bin/fake-trainer".into(),
            args: vec!["--safe".into()],
            cwd: None,
        }
    }

    #[test]
    fn trainer_security_requires_backend_and_exec_allow_gates() {
        let mut config = Config::default_template();
        config.security.exec_allow.clear();
        config.learning.adapter_training.allowed_backends = vec!["mlx-lm-lora".into()];

        let err = ensure_trainer_allowed(&config, "llama-cpp-finetune", &command())
            .expect_err("backend gate");
        let rendered = err.to_string();
        assert!(rendered.contains("learning.adapter_training.allowed_backends"));
        assert!(rendered.contains("security.exec_allow"));

        let err =
            ensure_trainer_allowed(&config, "mlx-lm-lora", &command()).expect_err("exec gate");
        let rendered = err.to_string();
        assert!(rendered.contains("learning.adapter_training.allowed_backends"));
        assert!(rendered.contains("security.exec_allow"));

        config
            .security
            .exec_allow
            .push("/usr/bin/fake-trainer".into());
        ensure_trainer_allowed(&config, "mlx-lm-lora", &command()).expect("allowed");
    }

    #[test]
    fn captured_output_gets_truncation_marker() {
        let output = capture_trainer_output(b"abcdef", b"0123456789", 8);
        assert!(!output.stdout_truncated);
        assert!(output.stderr_truncated);
        assert!(String::from_utf8_lossy(&output.stderr).contains(TRAINER_TRUNCATION_MARKER));
    }

    #[test]
    fn minimal_env_has_exact_allowlist_keys() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        let keys = minimal_trainer_env(&paths)
            .into_iter()
            .map(|(key, _)| key)
            .collect::<Vec<_>>();
        assert_eq!(keys, vec!["PATH", "HOME", "TMPDIR", "ALLBERT_HOME"]);
    }

    #[cfg(unix)]
    #[test]
    fn terminate_child_with_grace_stops_process() {
        let mut child = std::process::Command::new("sh")
            .arg("-c")
            .arg("trap 'exit 0' TERM; sleep 5")
            .spawn()
            .expect("spawn");
        terminate_child_with_grace(&mut child, Duration::from_secs(1)).expect("terminate");
        assert!(child.try_wait().expect("wait").is_some());
    }
}
