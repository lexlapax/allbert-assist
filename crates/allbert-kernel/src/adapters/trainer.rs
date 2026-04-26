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
