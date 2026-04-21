use std::path::Path;

use allbert_kernel::AllbertPaths;
use allbert_proto::ChannelKind;
use anyhow::{anyhow, Context, Result};
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::{Deserialize, Serialize};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ApprovalView {
    pub id: String,
    pub session_id: String,
    pub channel: ChannelKind,
    pub sender: String,
    pub agent: String,
    pub tool: String,
    pub request_id: u64,
    pub kind: String,
    pub requested_at: String,
    pub expires_at: String,
    pub status: String,
    pub resolved_at: Option<String>,
    pub resolver: Option<String>,
    pub reply: Option<String>,
    pub rendered: String,
    pub path: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct ApprovalFrontmatter {
    id: String,
    session_id: String,
    channel: ChannelKind,
    sender: String,
    agent: String,
    tool: String,
    request_id: u64,
    #[serde(default = "default_approval_kind")]
    kind: String,
    requested_at: String,
    expires_at: String,
    status: String,
    #[serde(default)]
    resolved_at: Option<String>,
    #[serde(default)]
    resolver: Option<String>,
    #[serde(default)]
    reply: Option<String>,
}

fn default_approval_kind() -> String {
    "tool-approval".to_string()
}

pub fn list(paths: &AllbertPaths, json: bool) -> Result<String> {
    let mut approvals = load_all(paths)?;
    approvals.retain(|approval| approval.status == "pending");
    approvals.sort_by(|a, b| b.requested_at.cmp(&a.requested_at));

    if json {
        return Ok(serde_json::to_string_pretty(&approvals)?);
    }

    if approvals.is_empty() {
        return Ok("no pending approvals".into());
    }

    let mut lines = vec!["pending approvals:".to_string()];
    for approval in approvals {
        lines.push(format!(
            "- {}  session={}  channel={}  tool={}  requested_at={}",
            approval.id,
            approval.session_id,
            channel_label(approval.channel),
            approval.tool,
            approval.requested_at
        ));
        lines.push(format!(
            "  sender={}  expires_at={}  agent={}",
            approval.sender, approval.expires_at, approval.agent
        ));
    }
    Ok(lines.join("\n"))
}

pub fn show(paths: &AllbertPaths, approval_id: &str, json: bool) -> Result<String> {
    let approval = load_all(paths)?
        .into_iter()
        .find(|approval| approval.id == approval_id)
        .ok_or_else(|| anyhow!("approval not found: {approval_id}"))?;

    if json {
        return Ok(serde_json::to_string_pretty(&approval)?);
    }

    Ok(format!(
        "approval:          {}\nsession:           {}\nchannel:           {}\nstatus:            {}\ntool:              {}\nagent:             {}\nsender:            {}\nrequested at:      {}\nexpires at:        {}\nresolved at:       {}\nresolver:          {}\nreply:             {}\nfile:              {}\n\n{}",
        approval.id,
        approval.session_id,
        channel_label(approval.channel),
        approval.status,
        approval.tool,
        approval.agent,
        approval.sender,
        approval.requested_at,
        approval.expires_at,
        approval.resolved_at.as_deref().unwrap_or("(pending)"),
        approval.resolver.as_deref().unwrap_or("(pending)"),
        approval.reply.as_deref().unwrap_or("(pending)"),
        approval.path,
        approval.rendered.trim(),
    ))
}

fn load_all(paths: &AllbertPaths) -> Result<Vec<ApprovalView>> {
    let mut approvals = Vec::new();
    if !paths.sessions.exists() {
        return Ok(approvals);
    }

    for session_entry in std::fs::read_dir(&paths.sessions)
        .with_context(|| format!("read {}", paths.sessions.display()))?
    {
        let session_entry = session_entry?;
        if !session_entry.file_type()?.is_dir() {
            continue;
        }
        let session_name = session_entry.file_name();
        if session_name.to_string_lossy().starts_with('.') {
            continue;
        }
        let approvals_dir = session_entry.path().join("approvals");
        if !approvals_dir.is_dir() {
            continue;
        }
        for entry in std::fs::read_dir(&approvals_dir)
            .with_context(|| format!("read {}", approvals_dir.display()))?
        {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            if entry.path().extension().and_then(|value| value.to_str()) != Some("md") {
                continue;
            }
            approvals.push(load_one(&entry.path())?);
        }
    }

    Ok(approvals)
}

fn load_one(path: &Path) -> Result<ApprovalView> {
    let raw = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<ApprovalFrontmatter>(&raw)
        .map_err(|err| anyhow!("parse approval {}: {err}", path.display()))?;
    let frontmatter = parsed
        .data
        .ok_or_else(|| anyhow!("approval file missing frontmatter: {}", path.display()))?;

    Ok(ApprovalView {
        id: frontmatter.id,
        session_id: frontmatter.session_id,
        channel: frontmatter.channel,
        sender: frontmatter.sender,
        agent: frontmatter.agent,
        tool: frontmatter.tool,
        request_id: frontmatter.request_id,
        kind: frontmatter.kind,
        requested_at: frontmatter.requested_at,
        expires_at: frontmatter.expires_at,
        status: frontmatter.status,
        resolved_at: frontmatter.resolved_at,
        resolver: frontmatter.resolver,
        reply: frontmatter.reply,
        rendered: parsed.content.trim().to_string(),
        path: path.display().to_string(),
    })
}

pub fn resolve(
    paths: &AllbertPaths,
    approval_id: &str,
    accept: bool,
    reason: Option<&str>,
) -> Result<String> {
    let approval = load_all(paths)?
        .into_iter()
        .find(|approval| approval.id == approval_id)
        .ok_or_else(|| anyhow!("approval not found: {approval_id}"))?;
    if approval.status != "pending" {
        return Ok(format!(
            "approval {} is already {}",
            approval.id, approval.status
        ));
    }
    let path = Path::new(&approval.path);
    let raw = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<ApprovalFrontmatter>(&raw)
        .map_err(|err| anyhow!("parse approval {}: {err}", path.display()))?;
    let mut frontmatter = parsed
        .data
        .ok_or_else(|| anyhow!("approval file missing frontmatter: {}", path.display()))?;
    frontmatter.status = if accept {
        "accepted".into()
    } else {
        "rejected".into()
    };
    frontmatter.resolved_at = Some(now_rfc3339());
    frontmatter.resolver = Some("cli".into());
    frontmatter.reply = reason.map(|value| value.to_string());
    let frontmatter = serde_yaml::to_string(&frontmatter)?;
    let rendered = format!("---\n{}---\n\n{}", frontmatter, parsed.content.trim());
    std::fs::write(path, rendered).with_context(|| format!("write {}", path.display()))?;
    Ok(format!(
        "{} {}",
        if accept { "accepted" } else { "rejected" },
        approval.id
    ))
}

fn now_rfc3339() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn channel_label(kind: ChannelKind) -> &'static str {
    match kind {
        ChannelKind::Cli => "cli",
        ChannelKind::Repl => "repl",
        ChannelKind::Jobs => "jobs",
        ChannelKind::Telegram => "telegram",
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let unique = format!(
                "allbert-approvals-{}-{}",
                std::process::id(),
                TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
            );
            let path = std::env::temp_dir().join(unique);
            std::fs::create_dir_all(&path).expect("temp root should create");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.clone())
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn list_filters_to_pending_entries() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");

        write_approval(
            &paths,
            "session-a",
            "appr_pending",
            "pending",
            "2026-04-20T10:00:00Z",
        );
        write_approval(
            &paths,
            "session-b",
            "appr_done",
            "accepted",
            "2026-04-20T09:00:00Z",
        );

        let rendered = list(&paths, false).expect("list should render");
        assert!(rendered.contains("appr_pending"));
        assert!(!rendered.contains("appr_done"));
    }

    #[test]
    fn show_renders_resolution_details() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        write_approval(
            &paths,
            "session-a",
            "appr_done",
            "accepted",
            "2026-04-20T10:00:00Z",
        );

        let rendered = show(&paths, "appr_done", false).expect("show should render");
        assert!(rendered.contains("approval:          appr_done"));
        assert!(rendered.contains("status:            accepted"));
        assert!(rendered.contains("process_exec --flag"));
    }

    fn write_approval(
        paths: &AllbertPaths,
        session_id: &str,
        approval_id: &str,
        status: &str,
        requested_at: &str,
    ) {
        let dir = paths.sessions.join(session_id).join("approvals");
        std::fs::create_dir_all(&dir).expect("approval dir should create");
        let content = format!(
            "---\nid: {approval_id}\nsession_id: {session_id}\nchannel: telegram\nsender: telegram:123\nagent: allbert/root\ntool: process_exec\nrequest_id: 7\nrequested_at: {requested_at}\nexpires_at: 2026-04-20T11:00:00Z\nstatus: {status}\nresolved_at: 2026-04-20T10:05:00Z\nresolver: telegram:123\nreply: approved\n---\n\nprocess_exec --flag\n"
        );
        std::fs::write(dir.join(format!("{approval_id}.md")), content)
            .expect("approval file should write");
    }
}
