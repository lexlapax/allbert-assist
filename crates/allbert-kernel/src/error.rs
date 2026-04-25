use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum KernelError {
    #[error("initialization failed: {0}")]
    InitFailed(String),
    #[error("config error: {0}")]
    Config(#[from] ConfigError),
    #[error("llm error: {0}")]
    Llm(#[from] LlmError),
    #[error("hook aborted turn: {0}")]
    Hook(String),
    #[error("{0}")]
    Request(String),
    #[error("cost tracking failed: {0}")]
    Cost(String),
    #[error("{0}")]
    CostCap(String),
    #[error("tracing init failed: {0}")]
    Trace(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("failed to parse config at {path}: {source}")]
    Parse {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },
    #[error("failed to write default config at {path}: {source}")]
    Write {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to serialize default config: {0}")]
    Serialize(#[from] toml::ser::Error),
}

#[derive(Debug, thiserror::Error)]
pub enum ToolError {
    #[error("tool not found: {0}")]
    NotFound(String),
    #[error("tool dispatch failed: {0}")]
    Dispatch(String),
}

#[derive(Debug, thiserror::Error)]
pub enum SkillError {
    #[error("skill not found: {0}")]
    NotFound(String),
    #[error("skill load failed: {0}")]
    Load(String),
}

#[derive(Debug, thiserror::Error)]
pub enum LlmError {
    #[error("missing API key in environment variable {0}")]
    MissingApiKeyEnv(String),
    #[error("unsupported provider: {0}")]
    UnsupportedProvider(String),
    #[error("request failed: {0}")]
    Http(String),
    #[error("unexpected provider response: {0}")]
    Response(String),
}

pub fn error_hint_for_message(message: &str) -> Option<&'static str> {
    let lower = message.to_ascii_lowercase();
    let has = |needle: &str| lower.contains(needle);

    if has("last-good config snapshot not found") {
        return Some("Fix config.toml manually or start the daemon once after a known-good config load so Allbert can write config.toml.last-good.");
    }
    if has("failed to parse config") || (has("parse") && has("config.toml")) {
        return Some("Run `allbert-cli config restore-last-good` if a daemon has started successfully before, or edit config.toml and retry.");
    }
    if has("invalid config") || has("config validation") {
        return Some("Run `allbert-cli settings list` and `allbert-cli settings show <key>` for supported values, then retry the command.");
    }
    if has("missing api key") || has("api key") && has("environment variable") {
        return Some("Export the named API key environment variable in the shell that starts Allbert, or choose a keyless/local provider.");
    }
    if has("ollama") && (has("connection refused") || has("connect") || has("unavailable")) {
        return Some("Start Ollama locally, verify the configured base URL, then retry; `ollama serve` is the usual local start command.");
    }
    if has("failed to connect to the daemon")
        || has("daemon unavailable")
        || has("daemon.sock")
        || has("connection refused")
    {
        return Some("Run `allbert-cli daemon status`, then `allbert-cli daemon start`; if the socket is stale, stop the daemon before retrying.");
    }
    if has("daemon lock") || has("already running") {
        return Some("Run `allbert-cli daemon status` and inspect `allbert-cli daemon logs`; remove locks only after confirming no daemon is running.");
    }
    if has("telegram") && has("missing bot token") {
        return Some("Add a Telegram bot token with `allbert-cli daemon channels add telegram`, then restart the daemon.");
    }
    if has("telegram") && (has("allowed chat") || has("allowlist") || has("not allowed")) {
        return Some("Add the chat id to the Telegram allowed-chats file or rerun `allbert-cli daemon channels add telegram`.");
    }
    if has("telegram") && (has("polling") || has("update handling")) {
        return Some("Check `allbert-cli daemon channels status telegram` and daemon logs for token, network, or allowlist details.");
    }
    if has("identity") && (has("not initialized") || has("missing")) {
        return Some("Run `allbert-cli setup --resume` or rerun setup so identity files and channel bindings are recreated.");
    }
    if has("session not found") || has("no session") {
        return Some("Run `allbert-cli sessions list` to find a resumable session, or start a new REPL session.");
    }
    if has("approval") && (has("expired") || has("not found") || has("no pending approval")) {
        return Some("Run `allbert-cli inbox list` to see current approvals; expired approvals usually require rerunning the original action.");
    }
    if has("job not found") {
        return Some("Run `allbert-cli jobs list` to see configured jobs before retrying.");
    }
    if has("skill") && (has("not installed") || has("not found")) {
        return Some("Run `allbert-cli skills list` and `allbert-cli skills show <name>` to confirm the installed skill name.");
    }
    if has("staged memory entry not found") || has("rejected staged memory entry not found") {
        return Some("Run `allbert-cli memory staged list` or inspect `allbert-cli memory status`; rejected entries can be reconsidered only while retained.");
    }
    if has("trashed memory entry not found") || has("no durable memory entries matched") {
        return Some("Run `allbert-cli memory status` and search with `allbert-cli memory search <query>`; trash entries are retained only for the configured window.");
    }
    if has("cost cap") || has("daily cost") {
        return Some("Use `/cost --override <reason>` in REPL/TUI or `/override <reason>` in Telegram to retry once with an operator reason.");
    }
    if has("permission denied") || has("operation not permitted") {
        return Some("Check ownership and permissions under ALLBERT_HOME, especially run/, logs/, config.toml, and channel secret files.");
    }
    if has("invalid timezone") {
        return Some("Use an IANA timezone such as America/Los_Angeles, then retry setup or the job command.");
    }
    if has("unsupported provider") || has("unknown provider") {
        return Some("Run `allbert-cli settings show model.provider` for supported providers, then update the model setting.");
    }
    None
}

pub fn append_error_hint(message: &str) -> String {
    match error_hint_for_message(message) {
        Some(hint) if !message.to_ascii_lowercase().contains("hint:") => {
            format!("{message}\n\nhint: {hint}")
        }
        _ => message.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::{append_error_hint, error_hint_for_message};

    #[test]
    fn error_hints_cover_primary_operator_failures() {
        for (message, expected) in [
            (
                "failed to parse config at /tmp/config.toml",
                "config restore-last-good",
            ),
            ("invalid config: repl.tui.tick_ms", "settings list"),
            (
                "missing API key in environment variable OPENAI_API_KEY",
                "Export the named API key",
            ),
            ("Ollama connection refused", "Start Ollama locally"),
            ("failed to connect to the daemon", "daemon status"),
            ("daemon lock is held by live process", "daemon status"),
            ("telegram missing bot token", "daemon channels add telegram"),
            ("telegram chat not allowed", "allowed-chats"),
            ("telegram polling error", "channels status telegram"),
            ("identity not initialized", "setup --resume"),
            ("session not found: abc", "sessions list"),
            ("approval expired", "inbox list"),
            ("job not found: daily", "jobs list"),
            ("skill not installed: helper", "skills list"),
            ("staged memory entry not found", "memory staged list"),
            ("trashed memory entry not found", "memory status"),
            ("daily cost cap exceeded", "/cost --override"),
            ("permission denied opening config", "permissions"),
            ("invalid timezone: Mars/Base", "IANA timezone"),
            ("unsupported provider: nope", "model.provider"),
            (
                "last-good config snapshot not found",
                "config.toml.last-good",
            ),
        ] {
            let hint = error_hint_for_message(message).unwrap_or_else(|| {
                panic!("missing hint for message: {message}");
            });
            assert!(
                hint.contains(expected),
                "hint `{hint}` did not contain `{expected}`"
            );
        }
    }

    #[test]
    fn append_error_hint_renders_separate_guidance_once() {
        let rendered = append_error_hint("session not found: gone");
        assert!(rendered.contains("\n\nhint: "));
        assert!(rendered.contains("sessions list"));
        assert_eq!(append_error_hint(&rendered), rendered);
    }
}
