use std::collections::HashSet;
use std::net::IpAddr;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use tokio::net::lookup_host;

use crate::adapter::{ConfirmDecision, ConfirmPrompter, ConfirmRequest};
use crate::config::{SecurityConfig, WebSecurityConfig};
use crate::hooks::{Hook, HookCtx, HookOutcome};
use crate::memory::{ReadMemoryInput, WriteMemoryInput, WriteMemoryMode};
use crate::skills::CreateSkillInput;
use crate::tools::{ProcessExecInput, WriteFileInput};
use crate::AllbertPaths;

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

pub async fn web_policy(url: &str, config: &WebSecurityConfig) -> PolicyDecision {
    let parsed = match reqwest::Url::parse(url) {
        Ok(parsed) => parsed,
        Err(err) => return PolicyDecision::Deny(format!("invalid url: {err}")),
    };

    match parsed.scheme() {
        "http" | "https" => {}
        scheme => return PolicyDecision::Deny(format!("scheme '{scheme}' is not allowed")),
    }

    let host = match parsed.host_str() {
        Some(host) => host.to_ascii_lowercase(),
        None => return PolicyDecision::Deny("url is missing a host".into()),
    };

    if host_matches(&host, &config.deny_hosts) {
        return PolicyDecision::Deny(format!("host '{host}' is denied by config"));
    }

    if !config.allow_hosts.is_empty() && !host_matches(&host, &config.allow_hosts) {
        return PolicyDecision::Deny(format!("host '{host}' is not allowlisted"));
    }

    let port = parsed.port_or_known_default().unwrap_or(80);
    let resolution = tokio::time::timeout(Duration::from_secs(config.timeout_s), async {
        lookup_host((host.as_str(), port)).await
    })
    .await;

    let addrs = match resolution {
        Ok(Ok(addrs)) => addrs.collect::<Vec<_>>(),
        Ok(Err(err)) => return PolicyDecision::Deny(format!("host lookup failed: {err}")),
        Err(_) => return PolicyDecision::Deny("host lookup timed out".into()),
    };

    if addrs.is_empty() {
        return PolicyDecision::Deny("host lookup returned no addresses".into());
    }

    if let Some(blocked) = addrs.into_iter().find(|addr| is_blocked_ip(addr.ip())) {
        return PolicyDecision::Deny(format!(
            "resolved address {} is blocked by SSRF policy",
            blocked.ip()
        ));
    }

    PolicyDecision::AutoAllow
}

pub mod sandbox {
    use super::{canonicalize_roots, normalize_path};
    use std::path::{Path, PathBuf};

    pub fn check(path: &Path, roots: &[PathBuf]) -> Result<PathBuf, String> {
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            std::env::current_dir()
                .map_err(|err| format!("resolve current dir: {err}"))?
                .join(path)
        };

        let canonical = absolute
            .canonicalize()
            .map_err(|err| format!("canonicalize {}: {err}", absolute.display()))?;
        let roots = canonicalize_roots(roots)?;
        if roots.iter().any(|root| canonical.starts_with(root)) {
            Ok(canonical)
        } else {
            Err(format!(
                "path {} is outside configured roots",
                canonical.display()
            ))
        }
    }

    pub fn check_write_target(path: &Path, roots: &[PathBuf]) -> Result<PathBuf, String> {
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            std::env::current_dir()
                .map_err(|err| format!("resolve current dir: {err}"))?
                .join(path)
        };

        let normalized = normalize_path(&absolute);
        let roots = canonicalize_roots(roots)?;
        if !roots.iter().any(|root| normalized.starts_with(root)) {
            return Err(format!(
                "path {} is outside configured roots",
                normalized.display()
            ));
        }

        let existing_ancestor = nearest_existing_ancestor(&normalized)
            .ok_or_else(|| format!("no existing ancestor for {}", normalized.display()))?;
        let canonical_ancestor = existing_ancestor
            .canonicalize()
            .map_err(|err| format!("canonicalize {}: {err}", existing_ancestor.display()))?;
        if roots
            .iter()
            .any(|root| canonical_ancestor.starts_with(root))
        {
            Ok(normalized)
        } else {
            Err(format!(
                "path {} escapes configured roots via symlinked parent",
                normalized.display()
            ))
        }
    }

    fn nearest_existing_ancestor(path: &Path) -> Option<PathBuf> {
        let mut current = path.to_path_buf();
        loop {
            if current.exists() {
                return Some(current);
            }
            current = current.parent()?.to_path_buf();
        }
    }
}

pub struct SecurityHook {
    security: Arc<Mutex<SecurityConfig>>,
    paths: AllbertPaths,
    confirm: Arc<dyn ConfirmPrompter>,
    approved_session_execs: Arc<Mutex<HashSet<String>>>,
}

impl SecurityHook {
    pub fn new(
        security: Arc<Mutex<SecurityConfig>>,
        paths: AllbertPaths,
        confirm: Arc<dyn ConfirmPrompter>,
    ) -> Self {
        Self {
            security,
            paths,
            confirm,
            approved_session_execs: Arc::new(Mutex::new(HashSet::new())),
        }
    }

    fn is_bootstrap_path(&self, path: &Path) -> bool {
        self.paths
            .bootstrap_files()
            .iter()
            .any(|(_, candidate)| *candidate == path)
    }
}

#[async_trait]
impl Hook for SecurityHook {
    async fn call(&self, ctx: &mut HookCtx) -> HookOutcome {
        let Some(invocation) = ctx.tool_invocation.as_ref() else {
            return HookOutcome::Continue;
        };
        let security = self.security.lock().unwrap().clone();
        let is_skill_script_exec = invocation.name == "process_exec"
            && invocation
                .input
                .get("_skill_script")
                .and_then(|value| value.as_bool())
                .unwrap_or(false);

        if let Some(allowed) = &ctx.active_allowed_tools {
            if !is_skill_script_exec
                && !tool_allowed_by_active_skills(invocation.name.as_str(), allowed)
            {
                return HookOutcome::Abort("tool not permitted by active skill(s)".into());
            }
        }

        match invocation.name.as_str() {
            "process_exec" => {
                let parsed =
                    match serde_json::from_value::<ProcessExecInput>(invocation.input.clone()) {
                        Ok(parsed) => parsed,
                        Err(err) => {
                            return HookOutcome::Abort(format!("invalid process_exec input: {err}"))
                        }
                    };
                let normalized = NormalizedExec {
                    program: parsed.program,
                    args: parsed.args.unwrap_or_default(),
                    cwd: parsed.cwd.map(PathBuf::from),
                };
                let approved = self.approved_session_execs.lock().unwrap().clone();
                match exec_policy(&normalized, &security, &approved) {
                    PolicyDecision::Deny(message) => HookOutcome::Abort(message),
                    PolicyDecision::AutoAllow => HookOutcome::Continue,
                    PolicyDecision::NeedsConfirm(request) => {
                        match self.confirm.confirm(request).await {
                            ConfirmDecision::Deny => {
                                HookOutcome::Abort("command denied by user".into())
                            }
                            ConfirmDecision::AllowOnce => HookOutcome::Continue,
                            ConfirmDecision::AllowSession => {
                                self.approved_session_execs
                                    .lock()
                                    .unwrap()
                                    .insert(normalized.session_key());
                                HookOutcome::Continue
                            }
                        }
                    }
                }
            }
            "read_file" => {
                let Some(path) = invocation
                    .input
                    .get("path")
                    .and_then(|value| value.as_str())
                    .map(PathBuf::from)
                else {
                    return HookOutcome::Abort("read_file.path must be a string".into());
                };
                match sandbox::check(&path, &security.fs_roots) {
                    Ok(_) => HookOutcome::Continue,
                    Err(message) => HookOutcome::Abort(message),
                }
            }
            "read_memory" => {
                let parsed =
                    match serde_json::from_value::<ReadMemoryInput>(invocation.input.clone()) {
                        Ok(parsed) => parsed,
                        Err(err) => {
                            return HookOutcome::Abort(format!("invalid read_memory input: {err}"))
                        }
                    };
                if Path::new(&parsed.path).is_absolute()
                    || Path::new(&parsed.path).components().any(|component| {
                        matches!(
                            component,
                            Component::ParentDir | Component::RootDir | Component::Prefix(_)
                        )
                    })
                {
                    return HookOutcome::Abort("memory path escapes memory root".into());
                }
                HookOutcome::Continue
            }
            "write_file" => {
                let parsed =
                    match serde_json::from_value::<WriteFileInput>(invocation.input.clone()) {
                        Ok(parsed) => parsed,
                        Err(err) => {
                            return HookOutcome::Abort(format!("invalid write_file input: {err}"))
                        }
                    };

                let target = match sandbox::check_write_target(
                    Path::new(&parsed.path),
                    &security.fs_roots,
                ) {
                    Ok(path) => path,
                    Err(message) => return HookOutcome::Abort(message),
                };

                let needs_confirm = target.exists() || self.is_bootstrap_path(&target);
                if !needs_confirm || security.auto_confirm {
                    return HookOutcome::Continue;
                }

                match self
                    .confirm
                    .confirm(ConfirmRequest {
                        program: "write_file".into(),
                        args: vec![target.display().to_string()],
                        cwd: None,
                        rendered: format!("write_file {}", target.display()),
                    })
                    .await
                {
                    ConfirmDecision::Deny => HookOutcome::Abort("write denied by user".into()),
                    ConfirmDecision::AllowOnce | ConfirmDecision::AllowSession => {
                        HookOutcome::Continue
                    }
                }
            }
            "write_memory" => {
                let parsed =
                    match serde_json::from_value::<WriteMemoryInput>(invocation.input.clone()) {
                        Ok(parsed) => parsed,
                        Err(err) => {
                            return HookOutcome::Abort(format!("invalid write_memory input: {err}"))
                        }
                    };

                if parsed.mode != WriteMemoryMode::Daily {
                    let Some(path) = parsed.path.as_ref() else {
                        return HookOutcome::Abort(
                            "write_memory.path is required for write/append".into(),
                        );
                    };
                    let path = Path::new(path);
                    if path.is_absolute()
                        || path.components().any(|component| {
                            matches!(
                                component,
                                Component::ParentDir | Component::RootDir | Component::Prefix(_)
                            )
                        })
                    {
                        return HookOutcome::Abort("memory path escapes memory root".into());
                    }
                }
                HookOutcome::Continue
            }
            "create_skill" => {
                let parsed =
                    match serde_json::from_value::<CreateSkillInput>(invocation.input.clone()) {
                        Ok(parsed) => parsed,
                        Err(err) => {
                            return HookOutcome::Abort(format!("invalid create_skill input: {err}"))
                        }
                    };

                let target = self.paths.skills.join(&parsed.name).join("SKILL.md");

                let needs_confirm = target.exists();
                if !needs_confirm || security.auto_confirm {
                    return HookOutcome::Continue;
                }

                match self
                    .confirm
                    .confirm(ConfirmRequest {
                        program: "create_skill".into(),
                        args: vec![target.display().to_string()],
                        cwd: None,
                        rendered: format!("create_skill {}", target.display()),
                    })
                    .await
                {
                    ConfirmDecision::Deny => {
                        HookOutcome::Abort("skill write denied by user".into())
                    }
                    ConfirmDecision::AllowOnce | ConfirmDecision::AllowSession => {
                        HookOutcome::Continue
                    }
                }
            }
            "fetch_url" => {
                let Some(url) = invocation.input.get("url").and_then(|value| value.as_str()) else {
                    return HookOutcome::Abort("fetch_url.url must be a string".into());
                };
                match web_policy(url, &security.web).await {
                    PolicyDecision::Deny(message) => HookOutcome::Abort(message),
                    PolicyDecision::AutoAllow | PolicyDecision::NeedsConfirm(_) => {
                        HookOutcome::Continue
                    }
                }
            }
            "web_search" => {
                match web_policy("https://html.duckduckgo.com/html/", &security.web).await {
                    PolicyDecision::Deny(message) => HookOutcome::Abort(message),
                    PolicyDecision::AutoAllow | PolicyDecision::NeedsConfirm(_) => {
                        HookOutcome::Continue
                    }
                }
            }
            _ => HookOutcome::Continue,
        }
    }
}

fn tool_allowed_by_active_skills(tool_name: &str, allowed: &HashSet<String>) -> bool {
    matches!(
        tool_name,
        "request_input" | "invoke_skill" | "list_skills" | "read_memory" | "read_reference"
    ) || allowed.contains(tool_name)
}

fn host_matches(host: &str, patterns: &[String]) -> bool {
    patterns
        .iter()
        .any(|pattern| host.eq_ignore_ascii_case(pattern))
}

fn is_blocked_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_private() || v4.is_loopback() || v4.is_link_local() || v4.is_unspecified()
        }
        IpAddr::V6(v6) => {
            v6.is_loopback()
                || v6.is_unique_local()
                || v6.is_unicast_link_local()
                || v6.is_unspecified()
        }
    }
}

fn canonicalize_roots(roots: &[PathBuf]) -> Result<Vec<PathBuf>, String> {
    roots
        .iter()
        .map(|root| {
            root.canonicalize()
                .map_err(|err| format!("canonicalize root {}: {err}", root.display()))
        })
        .collect()
}

fn normalize_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::RootDir => normalized.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Normal(part) => normalized.push(part),
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
        }
    }
    normalized
}

fn shell_quote(value: &str) -> String {
    if value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || "-_./".contains(ch))
    {
        value.to_string()
    } else {
        format!("{value:?}")
    }
}
