use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ClientKind {
    Cli,
    Repl,
    Jobs,
    Test,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum ChannelKind {
    Cli,
    Repl,
    Jobs,
}

impl ChannelKind {
    pub fn default_session_id(self) -> String {
        match self {
            Self::Repl => "repl-primary".into(),
            Self::Cli => "cli-default".into(),
            Self::Jobs => "jobs-default".into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ClientHello {
    pub protocol_version: u32,
    pub client_kind: ClientKind,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ServerHello {
    pub protocol_version: u32,
    pub daemon_id: String,
    pub pid: u32,
    pub started_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OpenChannel {
    pub channel: ChannelKind,
    pub session_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AttachedChannel {
    pub channel: ChannelKind,
    pub session_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DaemonStatus {
    pub daemon_id: String,
    pub pid: u32,
    pub socket_path: String,
    pub started_at: String,
    pub session_count: usize,
    pub trace_enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum ClientMessage {
    Hello(ClientHello),
    Attach(OpenChannel),
    Status,
    Shutdown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum ServerMessage {
    Hello(ServerHello),
    Attached(AttachedChannel),
    Status(DaemonStatus),
    Ack,
    Error(ProtocolError),
}
