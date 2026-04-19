use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum DaemonError {
    #[error("kernel error: {0}")]
    Kernel(#[from] allbert_kernel::KernelError),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("IPC error: {0}")]
    Ipc(String),
    #[error("daemon already running at {0}")]
    AlreadyRunning(PathBuf),
    #[error("protocol error: {0}")]
    Protocol(String),
    #[error("protocol version mismatch: client={client}, server={server}")]
    VersionMismatch { client: u32, server: u32 },
    #[error("spawn failed: {0}")]
    Spawn(String),
    #[error("timed out while waiting for {0}")]
    Timeout(&'static str),
}
