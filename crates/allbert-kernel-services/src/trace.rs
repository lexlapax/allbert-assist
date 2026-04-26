use std::path::PathBuf;

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::fmt;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Layer};

use crate::error::KernelError;
use crate::paths::AllbertPaths;

pub struct TraceHandles {
    pub guard: Option<WorkerGuard>,
    pub file_path: Option<PathBuf>,
}

pub fn init_tracing(
    enable_file_layer: bool,
    paths: &AllbertPaths,
    session_id: &str,
) -> Result<TraceHandles, KernelError> {
    let stderr_layer = fmt::layer()
        .with_writer(std::io::stderr)
        .with_target(false)
        .with_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")));

    if enable_file_layer {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let filename = format!("{session_id}-{ts}.log");
        let file_path = paths.traces.join(&filename);

        std::fs::create_dir_all(&paths.traces)
            .map_err(|e| KernelError::Trace(format!("create traces dir: {e}")))?;
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&file_path)
            .map_err(|e| KernelError::Trace(format!("open trace file: {e}")))?;

        let (writer, guard) = tracing_appender::non_blocking(file);
        let file_layer = fmt::layer()
            .with_writer(writer)
            .with_ansi(false)
            .with_target(true)
            .with_filter(EnvFilter::new("debug"));

        let init_res = tracing_subscriber::registry()
            .with(stderr_layer)
            .with(file_layer)
            .try_init();

        match init_res {
            Ok(()) => Ok(TraceHandles {
                guard: Some(guard),
                file_path: Some(file_path),
            }),
            Err(_) => Ok(TraceHandles {
                guard: None,
                file_path: None,
            }),
        }
    } else {
        let _ = tracing_subscriber::registry().with(stderr_layer).try_init();
        Ok(TraceHandles {
            guard: None,
            file_path: None,
        })
    }
}
