mod client;
mod error;
mod server;

pub use client::{default_spawn_config, DaemonClient, SpawnConfig};
pub use error::DaemonError;
pub use server::{spawn, spawn_with_factory, RunningDaemon};
