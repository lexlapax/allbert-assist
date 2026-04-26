use std::collections::HashSet;
use std::path::PathBuf;

use crate::adapter::ConfirmRequest;
use crate::config::SecurityConfig;

#[derive(Debug, Clone)]
pub enum PolicyDecision {
    Deny(String),
    AutoAllow,
    NeedsConfirm(ConfirmRequest),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedExec {
    pub program: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
}

impl NormalizedExec {
    pub fn render(&self) -> String {
        let mut rendered = self.program.clone();
        for arg in &self.args {
            rendered.push(' ');
            rendered.push_str(&shell_quote(arg));
        }
        if let Some(cwd) = &self.cwd {
            format!("(cd {} && {rendered})", cwd.display())
        } else {
            rendered
        }
    }

    pub fn session_key(&self) -> String {
        let cwd = self
            .cwd
            .as_ref()
            .map(|path| path.display().to_string())
            .unwrap_or_default();
        format!("{}|{}|{}", self.program, self.args.join("\u{1f}"), cwd)
    }
}

pub fn exec_policy(
    req: &NormalizedExec,
    security: &SecurityConfig,
    approved_session_execs: &HashSet<String>,
) -> PolicyDecision {
    if security
        .exec_deny
        .iter()
        .any(|pattern| pattern == &req.program)
    {
        return PolicyDecision::Deny(format!("program '{}' is denied by policy", req.program));
    }

    let session_key = req.session_key();
    if security.auto_confirm
        || approved_session_execs.contains(&session_key)
        || security
            .exec_allow
            .iter()
            .any(|pattern| pattern == &req.session_key() || pattern == &req.program)
    {
        return PolicyDecision::AutoAllow;
    }

    PolicyDecision::NeedsConfirm(ConfirmRequest {
        program: req.program.clone(),
        args: req.args.clone(),
        cwd: req.cwd.clone(),
        rendered: req.render(),
    })
}

fn shell_quote(arg: &str) -> String {
    if arg
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || "-_./:=+".contains(c))
    {
        arg.to_string()
    } else {
        format!("'{}'", arg.replace('\'', "'\\''"))
    }
}
